-- | Pure parsing and rendering for skills: SKILL.md frontmatter/body, the
-- @$ARGUMENTS@ substitution, and the invocation-line grammar shared by local
-- skills and MCP-prompt skills. No IO.
module OpenCode.Skill.Parse
  ( splitFrontmatter
  , parseSkillFile
  , substituteArgs
  , splitInvocation
  , parseArgs
  , missingArgs
  ) where

import Data.Aeson (FromJSON (..), withObject, (.:?))
import Data.Bifunctor (first)
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Yaml as Yaml

import OpenCode.Skill.Types (Skill (..), SkillSource (LocalSkill))

-- | Optional SKILL.md frontmatter fields.
data Frontmatter = Frontmatter
  { fmName :: Maybe Text, fmDescription :: Maybe Text }

instance FromJSON Frontmatter where
  parseJSON = withObject "Frontmatter" $ \o ->
    Frontmatter <$> o .:? "name" <*> o .:? "description"

emptyFrontmatter :: Frontmatter
emptyFrontmatter = Frontmatter Nothing Nothing

-- | Split a file into (optional raw frontmatter, body). Frontmatter is the text
-- between a leading @---@ line and the next @---@ line. With no opening fence (or
-- no closing fence) the whole input is the body and the frontmatter is 'Nothing'.
splitFrontmatter :: Text -> (Maybe Text, Text)
splitFrontmatter content =
  case T.lines content of
    (h : rest) | T.strip h == "---" ->
      case break ((== "---") . T.strip) rest of
        (fmLines, _closing : bodyLines) -> (Just (T.unlines fmLines), T.unlines bodyLines)
        (_, [])                         -> (Nothing, content)  -- unterminated fence
    _ -> (Nothing, content)

-- | Parse a SKILL.md file into a local 'Skill'. The first argument is the
-- fallback name (the skill's directory name), used when the frontmatter omits a
-- non-blank @name@. 'Left' carries a human-readable YAML error.
parseSkillFile :: Text -> Text -> Either Text Skill
parseSkillFile defName content = do
  let (mfm, body) = splitFrontmatter content
  fm <- maybe (Right emptyFrontmatter) decodeFrontmatter mfm
  Right Skill
    { skName         = fromMaybe defName (nonBlank =<< fmName fm)
    , skDescription  = fromMaybe "" (fmDescription fm)
    , skRequiredArgs = []
    , skSource       = LocalSkill (T.strip body)
    }
  where
    nonBlank t = if T.null (T.strip t) then Nothing else Just t
    decodeFrontmatter t
      | T.null (T.strip t) = Right emptyFrontmatter
      | otherwise = first (T.pack . Yaml.prettyPrintParseException)
                          (Yaml.decodeEither' (encodeUtf8 t))

-- | Render a skill body for the given trailing arguments. Every literal
-- @$ARGUMENTS@ is replaced by the args; if the body has no such token and the
-- args are non-empty, they are appended after a blank line.
substituteArgs :: Text -> Text -> Text
substituteArgs body args
  | placeholder `T.isInfixOf` body = T.replace placeholder args body
  | T.null (T.strip args)          = body
  | otherwise                      = body <> "\n\n" <> args
  where placeholder = "$ARGUMENTS"

-- | Split a @\/word rest...@ invocation line into (name without slash, trailing
-- text trimmed). 'Nothing' if not slash-prefixed or the name is empty.
splitInvocation :: Text -> Maybe (Text, Text)
splitInvocation raw =
  let s = T.stripStart raw
  in case T.uncons s of
       Just ('/', _) ->
         let (w, rest) = T.break isSpace s
             nm        = T.drop 1 w
         in if T.null nm then Nothing else Just (nm, T.strip rest)
       _ -> Nothing

-- | Parse @key=value@ tokens from trailing text. Splits each token on its first
-- @=@; tokens without @=@ are ignored; an empty value (@k=@) passes through.
parseArgs :: Text -> [(Text, Text)]
parseArgs rest =
  [ (k, T.drop 1 vEq)
  | tok <- T.words rest
  , let (k, vEq) = T.breakOn "=" tok
  , not (T.null k), not (T.null vEq)
  ]

-- | Required arg names absent from the supplied key=value pairs.
missingArgs :: [Text] -> [(Text, Text)] -> [Text]
missingArgs required supplied = [ a | a <- required, a `notElem` map fst supplied ]
