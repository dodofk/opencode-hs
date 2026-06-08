-- | Filesystem discovery of local skills. Scans skill roots in precedence order,
-- parses each @<root>/<name>/SKILL.md@, and collects a diagnostic for any skill
-- that cannot be read or parsed. Never throws.
module OpenCode.Skill.Discovery
  ( SkillDiagnostic (..)
  , discoverSkillsIn
  , defaultSkillRoots
  , discoverSkills
  ) where

import Control.Exception (IOException, try)
import Data.Either (fromRight, partitionEithers)
import Data.List (sort)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( doesDirectoryExist, doesFileExist, getCurrentDirectory
  , getHomeDirectory, listDirectory )
import System.FilePath ((</>))

import OpenCode.Skill.Parse (parseSkillFile)
import OpenCode.Skill.Types (Skill)

-- | One skill that was skipped, and why.
data SkillDiagnostic = SkillDiagnostic
  { sdSkill :: Text, sdReason :: Text }
  deriving stock (Show, Eq)

-- | Scan the given roots (in precedence order) for local skills. Within a root,
-- skills are returned sorted by directory name.
discoverSkillsIn :: [FilePath] -> IO ([Skill], [SkillDiagnostic])
discoverSkillsIn roots = do
  perRoot <- mapM scanRoot roots
  let (diags, skills) = partitionEithers (concat perRoot)
  pure (skills, diags)

-- | The default roots: project (@<cwd>/.opencode-hs/skills@) then user
-- (@<home>/.config/opencode-hs/skills@).
defaultSkillRoots :: IO [FilePath]
defaultSkillRoots = do
  cwd  <- getCurrentDirectory
  home <- getHomeDirectory
  pure [ cwd  </> ".opencode-hs" </> "skills"
       , home </> ".config" </> "opencode-hs" </> "skills" ]

-- | Discover skills under the default roots.
discoverSkills :: IO ([Skill], [SkillDiagnostic])
discoverSkills = defaultSkillRoots >>= discoverSkillsIn

-- | One root → results (errors 'Left', skills 'Right'); [] if the root is absent
-- or unreadable. The whole scan is wrapped in 'try' so a permission error on
-- 'doesDirectoryExist'\/'listDirectory' yields [] rather than escaping (the
-- module's "never throws" contract); per-skill read errors are still reported as
-- diagnostics by 'loadSkill'.
scanRoot :: FilePath -> IO [Either SkillDiagnostic Skill]
scanRoot root = do
  r <- try scan :: IO (Either IOException [Either SkillDiagnostic Skill])
  pure (fromRight [] r)
  where
    scan = do
      exists <- doesDirectoryExist root
      if not exists
        then pure []
        else do
          names   <- sort <$> listDirectory root
          results <- mapM (loadSkill root) names
          pure (catMaybes results)

-- | Load one @<root>/<name>/SKILL.md@. 'Nothing' for entries that are not a
-- directory or lack a SKILL.md (silently ignored, not a diagnostic).
loadSkill :: FilePath -> FilePath -> IO (Maybe (Either SkillDiagnostic Skill))
loadSkill root name = do
  let dir  = root </> name
      file = dir </> "SKILL.md"
  isDir   <- doesDirectoryExist dir
  hasFile <- doesFileExist file
  if not (isDir && hasFile)
    then pure Nothing
    else do
      r <- try (TIO.readFile file) :: IO (Either IOException Text)
      pure . Just $ case r of
        Left e        -> Left (SkillDiagnostic (T.pack name) (T.pack (show e)))
        Right content -> case parseSkillFile (T.pack name) content of
          Left err -> Left (SkillDiagnostic (T.pack name) err)
          Right sk -> Right sk
