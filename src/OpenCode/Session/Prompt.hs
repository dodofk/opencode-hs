-- | Builds the system-prompt string that gets passed to the LLM at the start
-- of every request. Includes a static agent header plus a per-tool block
-- enumerating available tools and their descriptions.
module OpenCode.Session.Prompt
  ( systemPrompt
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

import OpenCode.Tool.Types (SomeTool (..), ToolRegistry (..))

-- | Build the system prompt for the given registry.
systemPrompt :: ToolRegistry -> Text
systemPrompt (ToolRegistry reg) =
  let toolBlock = if Map.null reg
        then ""
        else "\n\nAvailable tools:\n" <> Text.unlines (map describeTool (Map.elems reg))
  in header <> toolBlock
  where
    header =
      "You are an AI coding assistant. You can read, write, and edit files\n\
      \via the tools listed below. When you need to make a change, call the\n\
      \appropriate tool. Be concise."

    describeTool t = "  - " <> toolName t <> ": " <> toolDesc t
