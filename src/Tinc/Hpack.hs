{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns #-}
module Tinc.Hpack (
  readConfig
, doesConfigExist
, render
, mkPackage
, extractAddSourceDependencies

#ifdef TEST
, parseAddSourceDependencies
, cacheAddSourceDep
, gitRefToRev
, isGitRev
, checkCabalName
, determinePackageName
, findCabalFile
#endif
) where

import           Prelude ()
import           Prelude.Compat

import           Control.Monad.Catch
import           Control.Monad.Compat
import           Control.Monad.IO.Class
import           Data.Function
import           Data.List.Compat
import           Distribution.Package
import           Distribution.PackageDescription
import           Distribution.PackageDescription.Parse
import           Distribution.Verbosity
import qualified Hpack.Config as Hpack
import           Hpack.Run
import           System.Directory hiding (getDirectoryContents)
import           System.FilePath
import           System.IO.Temp

import           Tinc.Fail
import           Tinc.Process
import           Tinc.Sandbox as Sandbox
import           Tinc.Types
import           Util

readConfig :: [Hpack.Dependency] -> IO Hpack.Package
readConfig additionalDeps = Hpack.readPackageConfig Hpack.packageConfig >>= either die (return . addDependencies . snd)
  where
    addDependencies :: Hpack.Package -> Hpack.Package
    addDependencies p
      | null additionalDeps = p
      | otherwise = (Hpack.renamePackage "tinc-generated" p) {Hpack.packageExecutables = mkExecutable additionalDeps : Hpack.packageExecutables p}

doesConfigExist :: IO Bool
doesConfigExist = doesFileExist Hpack.packageConfig

render :: Hpack.Package -> (FilePath, String)
render pkg = (name, contents)
  where
    name = Hpack.packageName pkg ++ ".cabal"
    contents = renderPackage defaultRenderSettings 2 [] pkg

mkPackage :: [Hpack.Dependency] -> Hpack.Package
mkPackage deps = (Hpack.package "tinc-generated" "0.0.0"){Hpack.packageExecutables = [mkExecutable deps]}

mkExecutable :: [Hpack.Dependency] -> Hpack.Section Hpack.Executable
mkExecutable deps = (Hpack.section $ Hpack.Executable "tinc-generated" "Generated.hs" []){Hpack.sectionDependencies = deps}

extractAddSourceDependencies :: Path AddSourceCache -> [Hpack.Dependency] -> IO [Sandbox.AddSource]
extractAddSourceDependencies addSourceCache additionalDeps =
  parseAddSourceDependencies additionalDeps >>= mapM resolveGitReferences >>= mapM (uncurry (cacheAddSourceDep addSourceCache))

resolveGitReferences :: (String, Hpack.AddSource) -> IO (String, Hpack.AddSource)
resolveGitReferences (name, addSource) = (,) name <$> case addSource of
  Hpack.GitRef url ref -> Hpack.GitRef url <$> gitRefToRev url ref
  Hpack.Local _ -> return addSource

parseAddSourceDependencies :: [Hpack.Dependency] ->  IO [(String, Hpack.AddSource)]
parseAddSourceDependencies additionalDeps = do
  exists <- doesFileExist Hpack.packageConfig
  packageDeps <- if exists
    then do
      pkg <- readConfig []
      return $ Hpack.packageDependencies pkg
    else return []
  let deps = nubBy ((==) `on` Hpack.dependencyName) (additionalDeps ++ packageDeps)
  return [(name, addSource) | Hpack.Dependency name (Just addSource) <- deps]

cacheAddSourceDep :: (Fail m, MonadProcess m, MonadIO m, MonadMask m) => Path AddSourceCache -> String -> Hpack.AddSource -> m Sandbox.AddSource
cacheAddSourceDep cache name dep = do
  liftIO $ createDirectoryIfMissing True (path cache)
  withTempDirectory (path cache) "tmp" $ \ sandbox -> do
    let tmp = sandbox </> name
    liftIO $ createDirectory tmp
    case dep of
      Hpack.GitRef url rev -> do
        let addSource = AddSource name rev
        alreadyInCache <- liftIO $ doesDirectoryExist (path $ addSourcePath cache addSource)
        unless alreadyInCache $ do
          cloneGit url rev tmp
          moveToAddSourceCache cache tmp dep addSource
        return addSource
      Hpack.Local dir -> liftIO $ do
        cabalSdist dir tmp
        fp <- fingerprint tmp
        let addSource = AddSource name fp
        moveToAddSourceCache cache tmp dep addSource
        return addSource

gitRefToRev :: (Fail m, MonadProcess m) => String -> String -> m String
gitRefToRev repo ref
  | isGitRev ref = return ref
  | otherwise = do
      r <- readProcess "git" ["ls-remote", repo, ref] ""
      case words r of
        rev : _ | isGitRev rev -> return rev
        _ -> die ("invalid reference " ++ show ref ++ " for git repository " ++ repo)

isGitRev :: String -> Bool
isGitRev ref = length ref == 40 && all (`elem` "0123456789abcdef") ref

cloneGit :: (MonadProcess m, MonadIO m, MonadMask m) => String -> String -> FilePath -> m ()
cloneGit url rev dst = do
  callProcess "git" ["clone", url, dst]
  withCurrentDirectory dst $ do
    callProcess "git" ["reset", "--hard", rev]
    liftIO $ removeDirectoryRecursive ".git"

cabalSdist :: FilePath -> FilePath -> IO ()
cabalSdist sourceDirectory dst = do
  withCurrentDirectory sourceDirectory $ do
    callProcess "cabal" ["sdist", "--output-directory", dst]

moveToAddSourceCache :: MonadIO m => Path AddSourceCache -> FilePath -> Hpack.AddSource -> Sandbox.AddSource -> m ()
moveToAddSourceCache cache src hpackDep dep@(AddSource name _) = liftIO $ do
  checkCabalName src name hpackDep
  let dst = addSourcePath cache dep
  exists <- doesDirectoryExist $ path dst
  unless exists $ do
    createDirectoryIfMissing True (path cache </> name)
    renameDirectory src $ path dst

checkCabalName :: (Fail m, MonadIO m) => FilePath -> String -> Hpack.AddSource -> m ()
checkCabalName directory expectedName addSource = do
  name <- determinePackageName directory addSource
  if name == expectedName
    then return ()
    else die ("the " ++ subject addSource ++ " contains package " ++ show name
      ++ ", expected: " ++ show expectedName)

subject :: Hpack.AddSource -> String
subject addSource = case addSource of
  Hpack.GitRef url _ -> "git repository " ++ url
  Hpack.Local dir -> "directory " ++ dir

determinePackageName :: (Fail m, MonadIO m) => FilePath -> Hpack.AddSource -> m String
determinePackageName directory dep = do
  cabalFile <- findCabalFile directory dep
  unPackageName . pkgName . package . packageDescription <$>
    liftIO (readPackageDescription silent cabalFile)

findCabalFile :: (Fail m, MonadIO m) => FilePath -> Hpack.AddSource -> m FilePath
findCabalFile dir addSource = do
  cabalFiles <- liftIO $ getCabalFiles dir
  case cabalFiles of
    [cabalFile] -> return (dir </> cabalFile)
    [] -> die ("Couldn't find .cabal file in " ++ subject addSource)
    _ -> die ("Multiple cabal files found in " ++ subject addSource)
