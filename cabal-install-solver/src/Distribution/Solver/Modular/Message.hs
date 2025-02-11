{-# LANGUAGE BangPatterns #-}

module Distribution.Solver.Modular.Message (
    Message(..),
    showMessages
  ) where

import qualified Data.List as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import Data.Maybe (catMaybes, mapMaybe)
import Prelude hiding (pi)

import Distribution.Pretty (prettyShow) -- from Cabal

import qualified Distribution.Solver.Modular.ConflictSet as CS
import Distribution.Solver.Modular.Dependency
import Distribution.Solver.Modular.Flag
import Distribution.Solver.Modular.MessageUtils
         (showUnsupportedExtension, showUnsupportedLanguage)
import Distribution.Solver.Modular.Package
import Distribution.Solver.Modular.Tree
         ( FailReason(..), POption(..), ConflictingDep(..) )
import Distribution.Solver.Modular.Version
import Distribution.Solver.Types.ConstraintSource
import Distribution.Solver.Types.PackagePath
import Distribution.Solver.Types.Progress
import Distribution.Types.LibraryName
import Distribution.Types.UnqualComponentName

data Message =
    Enter           -- ^ increase indentation level
  | Leave           -- ^ decrease indentation level
  | TryP QPN POption
  | TryF QFN Bool
  | TryS QSN Bool
  | Next (Goal QPN)
  | Skip (Set CS.Conflict)
  | Success
  | Failure ConflictSet FailReason

-- | Transforms the structured message type to actual messages (strings).
--
-- The log contains level numbers, which are useful for any trace that involves
-- backtracking, because only the level numbers will allow to keep track of
-- backjumps.
showMessages :: Progress Message a b -> Progress String a b
showMessages = go 0
  where
    -- 'go' increments the level for a recursive call when it encounters
    -- 'TryP', 'TryF', or 'TryS' and decrements the level when it encounters 'Leave'.
    go :: Int -> Progress Message a b -> Progress String a b
    go !_ (Done x)                           = Done x
    go !_ (Fail x)                           = Fail x
    -- complex patterns
    go !l (Step (TryP qpn i) (Step Enter (Step (Failure c fr) (Step Leave ms)))) =
        goPReject l qpn [i] c fr ms
    go !l (Step (TryP qpn i) (Step Enter (Step (Skip conflicts) (Step Leave ms)))) =
        goPSkip l qpn [i] conflicts ms
    go !l (Step (TryF qfn b) (Step Enter (Step (Failure c fr) (Step Leave ms)))) =
        (atLevel l $ "rejecting: " ++ showQFNBool qfn b ++ showFR c fr) (go l ms)
    go !l (Step (TryS qsn b) (Step Enter (Step (Failure c fr) (Step Leave ms)))) =
        (atLevel l $ "rejecting: " ++ showQSNBool qsn b ++ showFR c fr) (go l ms)
    go !l (Step (Next (Goal (P _  ) gr)) (Step (TryP qpn' i) ms@(Step Enter (Step (Next _) _)))) =
        (atLevel l $ "trying: " ++ showQPNPOpt qpn' i ++ showGR gr) (go l ms)
    go !l (Step (Next (Goal (P qpn) gr)) (Step (Failure _c UnknownPackage) ms)) =
        atLevel l ("unknown package: " ++ showQPN qpn ++ showGR gr) $ go l ms
    -- standard display
    go !l (Step Enter                    ms) = go (l+1) ms
    go !l (Step Leave                    ms) = go (l-1) ms
    go !l (Step (TryP qpn i)             ms) = (atLevel l $ "trying: " ++ showQPNPOpt qpn i) (go l ms)
    go !l (Step (TryF qfn b)             ms) = (atLevel l $ "trying: " ++ showQFNBool qfn b) (go l ms)
    go !l (Step (TryS qsn b)             ms) = (atLevel l $ "trying: " ++ showQSNBool qsn b) (go l ms)
    go !l (Step (Next (Goal (P qpn) gr)) ms) = (atLevel l $ showPackageGoal qpn gr) (go l ms)
    go !l (Step (Next _)                 ms) = go l     ms -- ignore flag goals in the log
    go !l (Step (Skip conflicts)         ms) =
        -- 'Skip' should always be handled by 'goPSkip' in the case above.
        (atLevel l $ "skipping: " ++ showConflicts conflicts) (go l ms)
    go !l (Step (Success)                ms) = (atLevel l $ "done") (go l ms)
    go !l (Step (Failure c fr)           ms) = (atLevel l $ showFailure c fr) (go l ms)

    showPackageGoal :: QPN -> QGoalReason -> String
    showPackageGoal qpn gr = "next goal: " ++ showQPN qpn ++ showGR gr

    showFailure :: ConflictSet -> FailReason -> String
    showFailure c fr = "fail" ++ showFR c fr

    -- special handler for many subsequent package rejections
    goPReject :: Int
              -> QPN
              -> [POption]
              -> ConflictSet
              -> FailReason
              -> Progress Message a b
              -> Progress String a b
    goPReject l qpn is c fr (Step (TryP qpn' i) (Step Enter (Step (Failure _ fr') (Step Leave ms))))
      | qpn == qpn' && fr == fr' = goPReject l qpn (i : is) c fr ms
    goPReject l qpn is c fr ms =
        (atLevel l $ "rejecting: " ++ L.intercalate ", " (map (showQPNPOpt qpn) (reverse is)) ++ showFR c fr) (go l ms)

    -- Handle many subsequent skipped package instances.
    goPSkip :: Int
            -> QPN
            -> [POption]
            -> Set CS.Conflict
            -> Progress Message a b
            -> Progress String a b
    goPSkip l qpn is conflicts (Step (TryP qpn' i) (Step Enter (Step (Skip conflicts') (Step Leave ms))))
      | qpn == qpn' && conflicts == conflicts' = goPSkip l qpn (i : is) conflicts ms
    goPSkip l qpn is conflicts ms =
      let msg = "skipping: "
                 ++ L.intercalate ", " (map (showQPNPOpt qpn) (reverse is))
                 ++ showConflicts conflicts
      in atLevel l msg (go l ms)

    -- write a message with the current level number
    atLevel :: Int -> String -> Progress String a b -> Progress String a b
    atLevel l x xs =
      let s = show l
      in  Step ("[" ++ replicate (3 - length s) '_' ++ s ++ "] " ++ x) xs

-- | Display the set of 'Conflicts' for a skipped package version.
showConflicts :: Set CS.Conflict -> String
showConflicts conflicts =
    " (has the same characteristics that caused the previous version to fail: "
     ++ conflictMsg ++ ")"
  where
    conflictMsg :: String
    conflictMsg =
      if S.member CS.OtherConflict conflicts
      then
        -- This case shouldn't happen, because an unknown conflict should not
        -- cause a version to be skipped.
        "unknown conflict"
      else let mergedConflicts =
                   [ showConflict qpn conflict
                   | (qpn, conflict) <- M.toList (mergeConflicts conflicts) ]
           in if L.null mergedConflicts
              then
                  -- This case shouldn't happen unless backjumping is turned off.
                  "none"
              else L.intercalate "; " mergedConflicts

    -- Merge conflicts to simplify the log message.
    mergeConflicts :: Set CS.Conflict -> Map QPN MergedPackageConflict
    mergeConflicts = M.fromListWith mergeConflict . mapMaybe toMergedConflict . S.toList
      where
        mergeConflict :: MergedPackageConflict
                      -> MergedPackageConflict
                      -> MergedPackageConflict
        mergeConflict mergedConflict1 mergedConflict2 = MergedPackageConflict {
              isGoalConflict =
                  isGoalConflict mergedConflict1 || isGoalConflict mergedConflict2
            , versionConstraintConflict =
                  L.nub $ versionConstraintConflict mergedConflict1
                       ++ versionConstraintConflict mergedConflict2
            , versionConflict =
                  mergeVersionConflicts (versionConflict mergedConflict1)
                                        (versionConflict mergedConflict2)
            }
          where
            mergeVersionConflicts (Just vr1) (Just vr2) = Just (vr1 .||. vr2)
            mergeVersionConflicts (Just vr1) Nothing    = Just vr1
            mergeVersionConflicts Nothing    (Just vr2) = Just vr2
            mergeVersionConflicts Nothing    Nothing    = Nothing

        toMergedConflict :: CS.Conflict -> Maybe (QPN, MergedPackageConflict)
        toMergedConflict (CS.GoalConflict qpn) =
            Just (qpn, MergedPackageConflict True [] Nothing)
        toMergedConflict (CS.VersionConstraintConflict qpn v) =
            Just (qpn, MergedPackageConflict False [v] Nothing)
        toMergedConflict (CS.VersionConflict qpn (CS.OrderedVersionRange vr)) =
            Just (qpn, MergedPackageConflict False [] (Just vr))
        toMergedConflict CS.OtherConflict = Nothing

    showConflict :: QPN -> MergedPackageConflict -> String
    showConflict qpn mergedConflict = L.intercalate "; " conflictStrings
      where
        conflictStrings = catMaybes [
            case () of
              () | isGoalConflict mergedConflict -> Just $
                     "depends on '" ++ showQPN qpn ++ "'" ++
                         (if null (versionConstraintConflict mergedConflict)
                          then ""
                          else " but excludes "
                                ++ showVersions (versionConstraintConflict mergedConflict))
                 | not $ L.null (versionConstraintConflict mergedConflict) -> Just $
                     "excludes '" ++ showQPN qpn
                      ++ "' " ++ showVersions (versionConstraintConflict mergedConflict)
                 | otherwise -> Nothing
          , (\vr -> "excluded by constraint '" ++ showVR vr ++ "' from '" ++ showQPN qpn ++ "'")
             <$> versionConflict mergedConflict
          ]

        showVersions []  = "no versions"
        showVersions [v] = "version " ++ showVer v
        showVersions vs  = "versions " ++ L.intercalate ", " (map showVer vs)

-- | All conflicts related to one package, used for simplifying the display of
-- a 'Set CS.Conflict'.
data MergedPackageConflict = MergedPackageConflict {
    isGoalConflict :: Bool
  , versionConstraintConflict :: [Ver]
  , versionConflict :: Maybe VR
  }

showQPNPOpt :: QPN -> POption -> String
showQPNPOpt qpn@(Q _pp pn) (POption i linkedTo) =
  case linkedTo of
    Nothing  -> showPI (PI qpn i) -- Consistent with prior to POption
    Just pp' -> showQPN qpn ++ "~>" ++ showPI (PI (Q pp' pn) i)

showGR :: QGoalReason -> String
showGR UserGoal            = " (user goal)"
showGR (DependencyGoal dr) = " (dependency of " ++ showDependencyReason dr ++ ")"

showFR :: ConflictSet -> FailReason -> String
showFR _ (UnsupportedExtension ext)       = " (conflict: requires " ++ showUnsupportedExtension ext ++ ")"
showFR _ (UnsupportedLanguage lang)       = " (conflict: requires " ++ showUnsupportedLanguage lang ++ ")"
showFR _ (MissingPkgconfigPackage pn vr)  = " (conflict: pkg-config package " ++ prettyShow pn ++ prettyShow vr ++ ", not found in the pkg-config database)"
showFR _ (NewPackageDoesNotMatchExistingConstraint d) = " (conflict: " ++ showConflictingDep d ++ ")"
showFR _ (ConflictingConstraints d1 d2)   = " (conflict: " ++ L.intercalate ", " (L.map showConflictingDep [d1, d2]) ++ ")"
showFR _ (NewPackageIsMissingRequiredComponent comp dr) = " (does not contain " ++ showExposedComponent comp ++ ", which is required by " ++ showDependencyReason dr ++ ")"
showFR _ (NewPackageHasPrivateRequiredComponent comp dr) = " (" ++ showExposedComponent comp ++ " is private, but it is required by " ++ showDependencyReason dr ++ ")"
showFR _ (NewPackageHasUnbuildableRequiredComponent comp dr) = " (" ++ showExposedComponent comp ++ " is not buildable in the current environment, but it is required by " ++ showDependencyReason dr ++ ")"
showFR _ (PackageRequiresMissingComponent qpn comp) = " (requires " ++ showExposedComponent comp ++ " from " ++ showQPN qpn ++ ", but the component does not exist)"
showFR _ (PackageRequiresPrivateComponent qpn comp) = " (requires " ++ showExposedComponent comp ++ " from " ++ showQPN qpn ++ ", but the component is private)"
showFR _ (PackageRequiresUnbuildableComponent qpn comp) = " (requires " ++ showExposedComponent comp ++ " from " ++ showQPN qpn ++ ", but the component is not buildable in the current environment)"
showFR _ CannotInstall                    = " (only already installed instances can be used)"
showFR _ CannotReinstall                  = " (avoiding to reinstall a package with same version but new dependencies)"
showFR _ NotExplicit                      = " (not a user-provided goal nor mentioned as a constraint, but reject-unconstrained-dependencies was set)"
showFR _ Shadowed                         = " (shadowed by another installed package with same version)"
showFR _ (Broken u)                       = " (package is broken, missing dependency " ++ prettyShow u ++ ")"
showFR _ UnknownPackage                   = " (unknown package)"
showFR _ (GlobalConstraintVersion vr src) = " (" ++ constraintSource src ++ " requires " ++ prettyShow vr ++ ")"
showFR _ (GlobalConstraintInstalled src)  = " (" ++ constraintSource src ++ " requires installed instance)"
showFR _ (GlobalConstraintSource src)     = " (" ++ constraintSource src ++ " requires source instance)"
showFR _ (GlobalConstraintFlag src)       = " (" ++ constraintSource src ++ " requires opposite flag selection)"
showFR _ ManualFlag                       = " (manual flag can only be changed explicitly)"
showFR c Backjump                         = " (backjumping, conflict set: " ++ showConflictSet c ++ ")"
showFR _ MultipleInstances                = " (multiple instances)"
showFR c (DependenciesNotLinked msg)      = " (dependencies not linked: " ++ msg ++ "; conflict set: " ++ showConflictSet c ++ ")"
showFR c CyclicDependencies               = " (cyclic dependencies; conflict set: " ++ showConflictSet c ++ ")"
showFR _ (UnsupportedSpecVer ver)         = " (unsupported spec-version " ++ prettyShow ver ++ ")"
-- The following are internal failures. They should not occur. In the
-- interest of not crashing unnecessarily, we still just print an error
-- message though.
showFR _ (MalformedFlagChoice qfn)        = " (INTERNAL ERROR: MALFORMED FLAG CHOICE: " ++ showQFN qfn ++ ")"
showFR _ (MalformedStanzaChoice qsn)      = " (INTERNAL ERROR: MALFORMED STANZA CHOICE: " ++ showQSN qsn ++ ")"
showFR _ EmptyGoalChoice                  = " (INTERNAL ERROR: EMPTY GOAL CHOICE)"

showExposedComponent :: ExposedComponent -> String
showExposedComponent (ExposedLib LMainLibName)       = "library"
showExposedComponent (ExposedLib (LSubLibName name)) = "library '" ++ unUnqualComponentName name ++ "'"
showExposedComponent (ExposedExe name)               = "executable '" ++ unUnqualComponentName name ++ "'"

constraintSource :: ConstraintSource -> String
constraintSource src = "constraint from " ++ showConstraintSource src

showConflictingDep :: ConflictingDep -> String
showConflictingDep (ConflictingDep dr (PkgComponent qpn comp) ci) =
  let DependencyReason qpn' _ _ = dr
      componentStr = case comp of
                       ExposedExe exe               -> " (exe " ++ unUnqualComponentName exe ++ ")"
                       ExposedLib LMainLibName      -> ""
                       ExposedLib (LSubLibName lib) -> " (lib " ++ unUnqualComponentName lib ++ ")"
  in case ci of
       Fixed i        -> (if qpn /= qpn' then showDependencyReason dr ++ " => " else "") ++
                         showQPN qpn ++ componentStr ++ "==" ++ showI i
       Constrained vr -> showDependencyReason dr ++ " => " ++ showQPN qpn ++
                         componentStr ++ showVR vr
