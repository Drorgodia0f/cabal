{-# LANGUAGE PatternGuards #-}
-- | See <https://github.com/ezyang/ghc-proposals/blob/backpack/proposals/0000-backpack.rst>
module Distribution.Backpack.ConfiguredComponent (
    ConfiguredComponent(..),
    cc_name,
    toConfiguredComponent,
    toConfiguredComponents,
    dispConfiguredComponent,

    ConfiguredComponentMap,
    extendConfiguredComponentMap,

    -- TODO: Should go somewhere else
    newPackageDepsBehaviour
) where

import Prelude ()
import Distribution.Compat.Prelude hiding ((<>))

import Distribution.Backpack.Id

import Distribution.Types.Dependency
import Distribution.Types.IncludeRenaming
import Distribution.Types.ComponentId
import Distribution.Types.PackageId
import Distribution.Types.PackageName
import Distribution.Types.Mixin
import Distribution.Types.ComponentName
import Distribution.Types.UnqualComponentName
import Distribution.Types.ComponentInclude
import Distribution.Package
import Distribution.PackageDescription as PD hiding (Flag)
import Distribution.Simple.BuildToolDepends
import Distribution.Simple.Setup as Setup
import Distribution.Simple.LocalBuildInfo
import Distribution.Version

import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Traversable
    ( mapAccumL )
import Distribution.Text
import Text.PrettyPrint

-- | A configured component, we know exactly what its 'ComponentId' is,
-- and the 'ComponentId's of the things it depends on.
data ConfiguredComponent
    = ConfiguredComponent {
        -- | Uniquely identifies a configured component.
        cc_cid :: ComponentId,
        -- | The package this component came from.
        cc_pkgid :: PackageId,
        -- | The fragment of syntax from the Cabal file describing this
        -- component.
        cc_component :: Component,
        -- | Is this the public library component of the package?
        -- (If we invoke Setup with an instantiation, this is the
        -- component the instantiation applies to.)
        -- Note that in one-component configure mode, this is
        -- always True, because any component is the "public" one.)
        cc_public :: Bool,
        -- | Dependencies on internal executables from @build-tools@.
        cc_internal_build_tools :: [ComponentId],
        -- | The mixins of this package, including both explicit (from
        -- the @mixins@ field) and implicit (from @build-depends@).  Not
        -- mix-in linked yet; component configuration only looks at
        -- 'ComponentId's.
        cc_includes :: [ComponentInclude ComponentId IncludeRenaming]
      }

-- | The 'ComponentName' of a component; this uniquely identifies
-- a fragment of syntax within a specified Cabal file describing the
-- component.
cc_name :: ConfiguredComponent -> ComponentName
cc_name = componentName . cc_component

-- | Pretty-print a 'ConfiguredComponent'.
dispConfiguredComponent :: ConfiguredComponent -> Doc
dispConfiguredComponent cc =
    hang (text "component" <+> disp (cc_cid cc)) 4
         (vcat [ hsep $ [ text "include", disp (ci_id incl), disp (ci_renaming incl) ]
               | incl <- cc_includes cc
               ])

-- | Construct a 'ConfiguredComponent', given that the 'ComponentId'
-- and library/executable dependencies are known.  The primary
-- work this does is handling implicit @backpack-include@ fields.
mkConfiguredComponent
    :: PackageDescription
    -> ComponentId
    -> [((PackageName, ComponentName), (ComponentId, PackageId))]
    -> [ComponentId]
    -> Component
    -> ConfiguredComponent
mkConfiguredComponent pkg_decr this_cid lib_deps exe_deps component =
    ConfiguredComponent {
        cc_cid = this_cid,
        cc_pkgid = package pkg_decr,
        cc_component = component,
        cc_public = is_public,
        cc_internal_build_tools = exe_deps,
        cc_includes = explicit_includes ++ implicit_includes
    }
  where
    bi = componentBuildInfo component
    deps_map = Map.fromList lib_deps

    -- Resolve each @mixins@ into the actual dependency
    -- from @lib_deps@.
    explicit_includes
        = [ let (cid, pid) =
                    case Map.lookup (fixFakePkgName pkg_decr name) deps_map of
                        Nothing ->
                            error $ "Mix-in refers to non-existent package " ++ display name ++
                                    " (did you forget to add the package to build-depends?)"
                        Just r  -> r
            in ComponentInclude {
                ci_id       = cid,
                -- TODO: We set pkgName = name here to make error messages
                -- look better. But it would be better to properly
                -- record component name here.
                ci_pkgid    = pid { pkgName = name },
                ci_renaming = rns,
                ci_implicit = False
               }
          | Mixin name rns <- mixins bi ]

    -- Any @build-depends@ which is not explicitly mentioned in
    -- @backpack-include@ is converted into an "implicit" include.
    used_explicitly = Set.fromList (map ci_id explicit_includes)
    implicit_includes
        = map (\((pn, _), (cid, pid)) -> ComponentInclude {
                                ci_id = cid,
                                -- See above ci_pkgid
                                ci_pkgid = pid { pkgName = pn },
                                ci_renaming = defaultIncludeRenaming,
                                ci_implicit = True
                              })
        $ filter (flip Set.notMember used_explicitly . fst . snd) lib_deps

    is_public = componentName component == CLibName

type ConfiguredComponentMap =
        (Map (PackageName, ComponentName) (ComponentId, PackageId), -- libraries
         Map UnqualComponentName ComponentId)      -- executables

-- Executable map must be different because an executable can
-- have the same name as a library. Ew.

toConfiguredComponent
    :: PackageDescription
    -> ComponentId
    -> ConfiguredComponentMap
    -> Component
    -> ConfiguredComponent
toConfiguredComponent pkg_descr this_cid (lib_map, exe_map) component =
    mkConfiguredComponent
       pkg_descr this_cid
       lib_deps exe_deps component
  where
    bi = componentBuildInfo component
    lib_deps
        | newPackageDepsBehaviour pkg_descr
        = [ (keys, value)
          | Dependency name _ <- targetBuildDepends bi
          , let keys@(pn, cn) = fixFakePkgName pkg_descr name
                value = flip fromMaybe (Map.lookup keys lib_map) $ error $
                  "toConfiguredComponent: " ++ display (packageName pkg_descr)
                  ++ " " ++ display pn ++ ":" ++ display cn ]
        | otherwise
        -- lib_map contains a mix of internal and external deps.
        -- We want all the public libraries (dep_cn == CLibName)
        -- of all external deps (dep /= pn).  Note that this
        -- excludes the public library of the current package:
        -- this is not supported by old-style deps behavior
        -- because it would imply a cyclic dependency for the
        -- library itself.
        = [ e
          | e@((pn,cn), _) <- Map.toList lib_map
          , pn /=  packageName pkg_descr
          , cn == CLibName ]
    exe_deps = [ cid
               | toolName <- getAllInternalToolDependencies pkg_descr bi
               , Just cid <- [ Map.lookup toolName exe_map ] ]

-- | Also computes the 'ComponentId', and sets cc_public if necessary.
-- This is Cabal-only; cabal-install won't use this.
toConfiguredComponent'
    :: Bool -- use_external_internal_deps
    -> FlagAssignment
    -> PackageDescription
    -> Bool -- deterministic
    -> Flag String      -- configIPID (todo: remove me)
    -> Flag ComponentId -- configCID
    -> ConfiguredComponentMap
    -> Component
    -> ConfiguredComponent
toConfiguredComponent' use_external_internal_deps flags
                pkg_descr deterministic ipid_flag cid_flag
                (lib_map, exe_map) component =
    let cc = toConfiguredComponent
                pkg_descr this_cid
                (lib_map, exe_map) component
    in if use_external_internal_deps
        then cc { cc_public = True }
        else cc
  where
    this_cid = computeComponentId deterministic ipid_flag cid_flag (package pkg_descr)
                (componentName component) (Just (deps, flags))
    deps = [ cid | ((dep_pn, _), (cid, _)) <- Map.toList lib_map
                 , dep_pn /= packageName pkg_descr ]

extendConfiguredComponentMap
    :: ConfiguredComponent
    -> ConfiguredComponentMap
    -> ConfiguredComponentMap
extendConfiguredComponentMap cc (lib_map, exe_map) =
    (lib_map', exe_map')
  where
    lib_map'
      = Map.insert (pkgName (cc_pkgid cc), cc_name cc) (cc_cid cc, cc_pkgid cc) lib_map
    exe_map'
      = case cc_name cc of
          CExeName str ->
            Map.insert str (cc_cid cc) exe_map
          _ -> exe_map

-- Compute the 'ComponentId's for a graph of 'Component's.  The
-- list of internal components must be topologically sorted
-- based on internal package dependencies, so that any internal
-- dependency points to an entry earlier in the list.
toConfiguredComponents
    :: Bool -- use_external_internal_deps
    -> FlagAssignment
    -> Bool -- deterministic
    -> Flag String -- configIPID
    -> Flag ComponentId -- configCID
    -> PackageDescription
    -> Map (PackageName, ComponentName) (ComponentId, PackageId)
    -> [Component]
    -> [ConfiguredComponent]
toConfiguredComponents
    use_external_internal_deps flags deterministic ipid_flag cid_flag pkg_descr
    external_lib_map comps
    = snd (mapAccumL go (external_lib_map, Map.empty) comps)
  where
    go m component = (extendConfiguredComponentMap cc m, cc)
      where cc = toConfiguredComponent'
                        use_external_internal_deps flags pkg_descr
                        deterministic ipid_flag cid_flag
                        m component


newPackageDepsBehaviourMinVersion :: Version
newPackageDepsBehaviourMinVersion = mkVersion [1,7,1]


-- In older cabal versions, there was only one set of package dependencies for
-- the whole package. In this version, we can have separate dependencies per
-- target, but we only enable this behaviour if the minimum cabal version
-- specified is >= a certain minimum. Otherwise, for compatibility we use the
-- old behaviour.
newPackageDepsBehaviour :: PackageDescription -> Bool
newPackageDepsBehaviour pkg =
   specVersion pkg >= newPackageDepsBehaviourMinVersion

-- | 'build-depends:' stanzas are currently ambiguous as the external packages
-- and internal libraries are specified the same. For now, we assume internal
-- libraries shadow, and this function disambiguates accordingly, but soon the
-- underlying ambiguity will be addressed.
fixFakePkgName :: PackageDescription -> PackageName -> (PackageName, ComponentName)
fixFakePkgName pkg_descr pn =
  if subLibName `elem` internalLibraries
  then (packageName pkg_descr, CSubLibName subLibName)
  else (pn,                    CLibName)
  where
    subLibName = packageNameToUnqualComponentName pn
    internalLibraries = mapMaybe libName (allLibraries pkg_descr)
