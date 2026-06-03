-- | Brick draw functions: convert 'AppState' into a list of widgets.
--
-- Renders the chat history in a scrollable viewport, a status bar, and the
-- input editor. While a run is active ('asRunState' /= 'Idle') and
-- 'asPartialText' is non-empty, appends a dim in-flight assistant message at
-- the bottom of the chat (M9).
module OpenCode.TUI.Render
  ( drawUI
    -- * Attribute names (consumed by the App's attr map)
  , userAttr
  , assistantAttr
  , toolAttr
  , errorAttr
  , statusAttr
  , streamingAttr
    -- * Internals (exported for testing)
  , safeWrap
  ) where

import Brick
  ( Padding (Max, Pad)
  , Widget
  , (<+>)
  , (<=>)
  )
import Brick.AttrMap (AttrName, attrName)
import qualified Brick.Widgets.Border as B
import Brick.Widgets.Core
  ( padLeft
  , padRight
  , str
  , txt
  , txtWrap
  , vBox
  , vLimit
  , viewport
  , withAttr
  )
import qualified Brick.Widgets.Edit as E
import Brick.Types (ViewportType (Vertical))
import Data.Foldable (toList)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T

import OpenCode.Session.Events (RunState (..))
import OpenCode.TUI.Types (AppState (..), ResourceName (..))
import OpenCode.Types
  ( Message (..)
  , MessagePart (..)
  , Role (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )

-- ---------------------------------------------------------------------------
-- Attribute names
-- ---------------------------------------------------------------------------

userAttr, assistantAttr, toolAttr, errorAttr, statusAttr :: AttrName
userAttr      = attrName "user"
assistantAttr = attrName "assistant"
toolAttr      = attrName "tool"
errorAttr     = attrName "error"
statusAttr    = attrName "status"

streamingAttr :: AttrName
streamingAttr = attrName "streaming"

-- ---------------------------------------------------------------------------
-- Top-level layout
-- ---------------------------------------------------------------------------

-- | Top-level draw function passed to 'Brick.Main.App'.
drawUI :: AppState -> [Widget ResourceName]
drawUI st = [chat <=> statusBar st <=> inputBox st]
  where
    chat =
      viewport ChatViewport Vertical $
        vBox (map renderMessage (toList (asMessages st)) <> inflight)
    inflight
      | asRunState st /= Idle && not (T.null (asPartialText st)) =
          [ withAttr assistantAttr (txt (rolePrefix RoleAssistant))
              <=> padLeft (Pad 2) (withAttr streamingAttr (safeWrap (asPartialText st)))
          ]
      | otherwise = []

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

statusBar :: AppState -> Widget ResourceName
statusBar st =
  withAttr statusAttr $
    vLimit 1 $
      padRight Max (txt (asStatusLine st))
        <+> txt (runStateLabel (asRunState st))

runStateLabel :: RunState -> Text
runStateLabel = \case
  Idle           -> "idle"
  RunningLLM     -> "thinking…"
  RunningTool n  -> "running " <> n <> "…"
  AwaitingInput  -> "awaiting input"

-- ---------------------------------------------------------------------------
-- Input editor
-- ---------------------------------------------------------------------------

inputBox :: AppState -> Widget ResourceName
inputBox st =
  B.borderWithLabel (txt " input ") $
    vLimit 3 $
      E.renderEditor (txt . T.unlines) True (asInput st)

-- ---------------------------------------------------------------------------
-- Message rendering
-- ---------------------------------------------------------------------------

renderMessage :: Message -> Widget ResourceName
renderMessage m =
  roleHeader (msgRole m)
    <=> padLeft (Pad 2) (vBox (map renderPart (NE.toList (msgParts m))))

roleHeader :: Role -> Widget ResourceName
roleHeader r = withAttr (roleAttr r) (txt (rolePrefix r))

rolePrefix :: Role -> Text
rolePrefix = \case
  RoleUser      -> "▌ you"
  RoleAssistant -> "▌ assistant"
  RoleTool      -> "▌ tool"

roleAttr :: Role -> AttrName
roleAttr = \case
  RoleUser      -> userAttr
  RoleAssistant -> assistantAttr
  RoleTool      -> toolAttr

renderPart :: MessagePart -> Widget ResourceName
renderPart = \case
  TextPart t       -> safeWrap t
  ToolCallPart tc  -> withAttr toolAttr (txt (renderToolCall tc))
  ToolResultPart r -> padLeft (Pad 2) (safeWrap (content r))
  ErrorPart e      -> withAttr errorAttr (safeWrap e)

renderToolCall :: ToolCall -> Text
renderToolCall tc =
  "⚙ " <> toolName tc <> "(" <> unToolArgs (arguments tc) <> ")"

-- | 'txtWrap' renders nothing for an empty string, which produces an empty
-- vty image; substitute a single space so vertical layout stays stable.
safeWrap :: Text -> Widget ResourceName
safeWrap t
  | T.null t  = str " "
  | otherwise = txtWrap t
