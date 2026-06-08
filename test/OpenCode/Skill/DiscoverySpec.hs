{-# LANGUAGE OverloadedStrings #-}
module OpenCode.Skill.DiscoverySpec (spec) where

import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.Skill.Discovery
import OpenCode.Skill.Types (Skill (..))

-- | Write @<root>/<name>/SKILL.md@ with the given contents.
writeSkill :: FilePath -> FilePath -> Text -> IO ()
writeSkill root name contents = do
  let dir = root </> name
  createDirectoryIfMissing True dir
  TIO.writeFile (dir </> "SKILL.md") contents

spec :: Spec
spec = describe "discoverSkillsIn" $ do
  it "finds skills in a single root, sorted by directory name" $
    withSystemTempDirectory "skills-one" $ \root -> do
      writeSkill root "beta"  "---\ndescription: b\n---\nB"
      writeSkill root "alpha" "---\ndescription: a\n---\nA"
      (skills, diags) <- discoverSkillsIn [root]
      map skName skills `shouldBe` ["alpha", "beta"]
      diags `shouldBe` []

  it "returns both roots' skills in root order (project first)" $
    withSystemTempDirectory "skills-proj" $ \proj ->
      withSystemTempDirectory "skills-user" $ \user -> do
        writeSkill proj "greet" "---\ndescription: project\n---\nP"
        writeSkill user "greet" "---\ndescription: user\n---\nU"
        (skills, _) <- discoverSkillsIn [proj, user]
        map skDescription skills `shouldBe` ["project", "user"]

  it "collects a diagnostic for a malformed SKILL.md and keeps the good ones" $
    withSystemTempDirectory "skills-bad" $ \root -> do
      writeSkill root "good" "---\ndescription: ok\n---\nbody"
      writeSkill root "bad"  "---\nnot an object\n---\nbody"
      (skills, diags) <- discoverSkillsIn [root]
      map skName skills `shouldBe` ["good"]
      map sdSkill diags `shouldBe` ["bad"]

  it "ignores a directory without a SKILL.md" $
    withSystemTempDirectory "skills-empty" $ \root -> do
      createDirectoryIfMissing True (root </> "notaskill")
      (skills, diags) <- discoverSkillsIn [root]
      skills `shouldBe` []
      diags  `shouldBe` []

  it "ignores a plain file in the root (not a skill directory)" $
    withSystemTempDirectory "skills-plainfile" $ \root -> do
      TIO.writeFile (root </> "README.md") "not a skill"
      (skills, diags) <- discoverSkillsIn [root]
      skills `shouldBe` []
      diags  `shouldBe` []

  it "returns nothing for a non-existent root" $ do
    (skills, diags) <- discoverSkillsIn ["/no/such/path/skills"]
    skills `shouldBe` []
    diags  `shouldBe` []
