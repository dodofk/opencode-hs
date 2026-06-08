-- | Pure merge, lookup, and autocomplete for the unified skill list. Knows
-- nothing of MCP or the TUI — callers pass candidates already in precedence
-- order and a list of reserved (built-in command) names to exclude.
module OpenCode.Skill.Registry
  ( buildSkillRegistry
  , lookupSkill
  , matchSkill
  , skillSuggestEntries
  ) where

import Data.List (find)
import Data.Text (Text)

import OpenCode.Skill.Parse (splitInvocation)
import OpenCode.Skill.Types (Skill (..))

-- | Merge candidate skills into a registry. Earlier candidates win on a name
-- clash, and any candidate whose name is reserved (a built-in command) is
-- dropped. Callers order candidates project-skills, then user-skills, then
-- MCP-prompt skills, giving precedence built-in > project > user > mcp.
buildSkillRegistry :: [Text] -> [Skill] -> [Skill]
buildSkillRegistry reserved = go []
  where
    go acc [] = reverse acc
    go acc (s : ss)
      | skName s `elem` reserved        = go acc ss
      | skName s `elem` map skName acc  = go acc ss
      | otherwise                       = go (s : acc) ss

-- | Find a skill by exact name.
lookupSkill :: Text -> [Skill] -> Maybe Skill
lookupSkill nm = find ((== nm) . skName)

-- | Resolve an invocation line against the registry: split the @\/name rest@
-- line, look the name up, and return the skill with the raw trailing text.
matchSkill :: [Skill] -> Text -> Maybe (Skill, Text)
matchSkill skills body = do
  (nm, rest) <- splitInvocation body
  s          <- lookupSkill nm skills
  pure (s, rest)

-- | Autocomplete entries (slash-prefixed name + description) for the registry.
skillSuggestEntries :: [Skill] -> [(Text, Text)]
skillSuggestEntries = map (\s -> ("/" <> skName s, skDescription s))
