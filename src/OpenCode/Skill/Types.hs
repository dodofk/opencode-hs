-- | Core skill data: a named instruction bundle and where it came from. Pure
-- data with no app-specific imports — in particular the MCP variant holds plain
-- 'Text', so this module does not depend on @OpenCode.MCP.*@.
module OpenCode.Skill.Types
  ( Skill (..)
  , SkillSource (..)
  ) where

import Data.Text (Text)

-- | Where a skill's text comes from.
data SkillSource
  = LocalSkill Text            -- ^ the SKILL.md body (may contain @$ARGUMENTS@)
  | McpPromptSkill Text Text   -- ^ server name, raw prompt name
  deriving stock (Show, Eq)

-- | A named, invocable instruction bundle.
data Skill = Skill
  { skName         :: Text     -- ^ invocation name, no leading slash
  , skDescription  :: Text     -- ^ shown in the listing
  , skRequiredArgs :: [Text]   -- ^ required arg names ([] for local skills)
  , skSource       :: SkillSource
  }
  deriving stock (Show, Eq)
