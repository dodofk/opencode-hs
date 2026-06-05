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
  , leftLabel
  ) where

import Brick
  ( Padding (Max, Pad)
  , Widget
  , emptyWidget
  , (<+>)
  , (<=>)
  )
import Brick.AttrMap (AttrName, attrName)
import qualified Brick.Widgets.Border as B
import Brick.Widgets.Center (centerLayer)
import Brick.Widgets.Core
  ( hLimit
  , padLeft
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
import OpenCode.TUI.Command (clampSel, commandSuggestions)
import OpenCode.TUI.Overlay (overlayLabels)
import OpenCode.TUI.Types (AppState (..), Overlay (..), ResourceName (..), UIMode (..))
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

-- | Top-level draw function passed to 'Brick.Main.App'. When an overlay is
-- open it is drawn as the first (top) layer over the chat.
drawUI :: AppState -> [Widget ResourceName]
drawUI st = overlayLayer (asMode st)
  <> [chat <=> statusBar st <=> suggestBox st <=> inputBox st]
  where
    overlayLayer ModeNormal       = []
    overlayLayer (ModeOverlay ov) = [renderOverlay ov]
    chat =
      viewport ChatViewport Vertical $
        vBox (map renderMessage (toList (asMessages st)) <> reasoningBlock <> partialBlock)
    reasoningBlock
      | asRunState st /= Idle && not (T.null (asPartialReasoning st)) =
          [ withAttr streamingAttr (txt "💭 thinking")
              <=> padLeft (Pad 2) (withAttr streamingAttr (safeWrap (asPartialReasoning st)))
          ]
      | otherwise = []
    partialBlock
      | asRunState st /= Idle && not (T.null (asPartialText st)) =
          [ withAttr assistantAttr (txt (rolePrefix RoleAssistant))
              <=> padLeft (Pad 2) (withAttr streamingAttr (safeWrap (asPartialText st)))
          ]
      | otherwise = []

-- ---------------------------------------------------------------------------
-- Overlay (modal picker)
-- ---------------------------------------------------------------------------

-- | Draw a centered, bordered picker. The selected row is shown with the
-- 'statusAttr' highlight bar. Pure data comes from 'OpenCode.TUI.Overlay'.
renderOverlay :: Overlay -> Widget ResourceName
renderOverlay ov =
  centerLayer $
    B.borderWithLabel (txt (" " <> ovTitle ov <> " ")) $
      hLimit 60 $
        vBox (zipWith renderRow [0 ..] (overlayLabels (ovKind ov)))
  where
    renderRow :: Int -> Text -> Widget ResourceName
    renderRow i label
      | i == ovSel ov = withAttr statusAttr (padRight Max (txt (" " <> label)))
      | otherwise     = padRight Max (txt (" " <> label))

-- ---------------------------------------------------------------------------
-- Slash-command autocomplete panel (non-modal; shown above the input)
-- ---------------------------------------------------------------------------

-- | A non-modal panel of slash-command suggestions, shown while the input line
-- begins with @\/@ and matches at least one command. 'Brick.emptyWidget' when
-- there are no matches. The row at 'asSuggestSel' (clamped) gets the highlight
-- bar (same look as overlay rows).
suggestBox :: AppState -> Widget ResourceName
suggestBox st =
  case commandSuggestions (currentInputText st) of
    [] -> emptyWidget
    xs ->
      B.borderWithLabel (txt " commands ") $
        hLimit 60 $
          vBox (zipWith renderRow [0 ..] xs)
      where
        sel = clampSel (length xs) (asSuggestSel st)
        renderRow :: Int -> (Text, Text) -> Widget ResourceName
        renderRow i (name, desc)
          | i == sel  = withAttr statusAttr (padRight Max (txt (rowText name desc)))
          | otherwise = padRight Max (txt (rowText name desc))
        rowText name desc = " " <> name <> "  " <> desc

-- | The input line as plain text. Mirrors 'OpenCode.TUI.App.currentInput',
-- duplicated here to avoid a Render -> App import cycle.
currentInputText :: AppState -> Text
currentInputText = T.intercalate "\n" . E.getEditContents . asInput

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

statusBar :: AppState -> Widget ResourceName
statusBar st =
  withAttr statusAttr $
    vLimit 1 $
      padRight Max (txt (leftLabel st)) <+> txt (rightText st)

-- | Right-hand status segment: a transient notice when present, else the
-- run-state and round indicator.
rightText :: AppState -> Text
rightText st = case asNotice st of
  Just n  -> n
  Nothing -> runStateLabel (asRunState st) <> roundSuffix (asRound st)

leftLabel :: AppState -> Text
leftLabel st
  | t /= "" && t /= "untitled" = t <> " \8212 " <> asStatusLine st
  | otherwise                  = asStatusLine st
  where t = asTitle st

roundSuffix :: Maybe (Int, Int) -> Text
roundSuffix Nothing           = ""
roundSuffix (Just (cur, tot)) = " · round " <> tshow cur <> "/" <> tshow tot

tshow :: Int -> Text
tshow = T.pack . show

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
