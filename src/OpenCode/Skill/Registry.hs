-- | Pure merge, lookup, autocomplete, and tool schema/description building for
-- the unified skill list. Knows nothing of MCP or the TUI — callers pass
-- candidates already in precedence order and a list of reserved (built-in
-- command) names to exclude.
module OpenCode.Skill.Registry
  ( buildSkillRegistry
  , lookupSkill
  , matchSkill
  , skillSuggestEntries
  , skillToolDescription
  , skillToolSchema
  ) where

import Data.Aeson (Value, object, (.=))
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T

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

-- | Tool description for the umbrella @skill@ tool: an invocation instruction
-- plus one line per skill. MCP-prompt skills with required args advertise them
-- as @(needs: a, b)@ so the model supplies @key=value@ pairs in @arguments@.
skillToolDescription :: [Skill] -> Text
skillToolDescription skills = T.intercalate "\n" (header : map line skills)
  where
    header =
      "Invoke a named skill: a reusable instruction bundle. The result is the \
      \skill's instructions; follow them. Available skills:"
    line s = "  - " <> skName s <> ": " <> skDescription s <> needs (skRequiredArgs s)
    needs [] = ""
    needs as = " (needs: " <> T.intercalate ", " as <> ")"

-- | Input schema for the umbrella @skill@ tool. The @name@ enum lists exactly
-- the registered skill names, so an invalid name is unrepresentable at the
-- wire level.
skillToolSchema :: [Skill] -> Value
skillToolSchema skills = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "name" .= object
          [ "type" .= ("string" :: Text)
          , "enum" .= map skName skills
          ]
      , "arguments" .= object
          [ "type" .= ("string" :: Text)
          , "description" .=
              ("free text for the skill; for skills with required args, \
               \key=value pairs" :: Text)
          ]
      ]
  , "required" .= (["name"] :: [Text])
  ]
