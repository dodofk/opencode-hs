-- | Pure logic for the TUI modal overlay (session / model / help pickers).
--
-- No brick, no IO: navigation, selection, smart constructors, and row labels
-- are pure so they can be unit-tested directly. Rendering lives in
-- 'OpenCode.TUI.Render' (it needs brick attrs).
module OpenCode.TUI.Overlay
  ( overlayCount
  , overlayMove
  , overlaySelected
  , overlayLabels
  , sessionsOverlay
  , modelsOverlay
  , helpOverlay
  , skillsOverlay
  ) where

import Data.List (elemIndex)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)

import OpenCode.Skill.Types (Skill (..), SkillSource (..))
import OpenCode.Model.Catalog (modelLabel)
import OpenCode.TUI.Command (commandCatalog)
import OpenCode.TUI.Types (Overlay (..), OverlayKind (..))
import OpenCode.Types (ModelId, Session (..), SessionId)

-- | Number of selectable rows in an overlay kind.
overlayCount :: OverlayKind -> Int
overlayCount = \case
  OverlaySessions _ ss -> length ss
  OverlayModels   _ ms -> length ms
  OverlayHelp     ls   -> length ls
  OverlaySkills   ss   -> length ss

-- | Move the selection by a delta, clamped to @[0, count-1]@ (no-op if empty).
overlayMove :: Int -> Overlay -> Overlay
overlayMove delta ov = ov { ovSel = clamp (ovSel ov + delta) }
  where
    n = overlayCount (ovKind ov)
    clamp i
      | n <= 0    = 0
      | i < 0     = 0
      | i >= n    = n - 1
      | otherwise = i

-- | The selected row index, or 'Nothing' when the overlay has no rows.
overlaySelected :: Overlay -> Maybe Int
overlaySelected ov
  | overlayCount (ovKind ov) <= 0 = Nothing
  | otherwise                     = Just (ovSel ov)

-- | Display label per row, in payload order. The current session/model is
-- marked with a leading @* @; other rows get a @  @ pad so columns align.
overlayLabels :: OverlayKind -> [Text]
overlayLabels = \case
  OverlaySessions cur ss -> map (sessionRow cur) ss
  OverlayModels   cur ms -> map (modelRow cur) ms
  OverlayHelp     ls     -> ls
  OverlaySkills   ss     -> map skillRow ss
  where
    sessionRow cur s = marker (sessionId s == cur) <> titleOf s <> "  " <> createdLabel s
    createdLabel s   = T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M" (sessionCreated s))
    titleOf s
      | T.null (sessionTitle s) = "(untitled)"
      | otherwise               = sessionTitle s
    modelRow cur m = marker (m == cur) <> modelLabel m
    skillRow s = skName s <> descPart (skDescription s) <> srcTag (skSource s)
    descPart d | T.null d  = ""
               | otherwise = "  " <> d
    srcTag (LocalSkill _)         = ""
    srcTag (McpPromptSkill srv _) = "  (mcp:" <> srv <> ")"
    marker True  = "* "
    marker False = "  "

-- | A sessions overlay; current session marked, selection at the top.
sessionsOverlay :: SessionId -> [Session] -> Overlay
sessionsOverlay cur ss = Overlay
  { ovTitle = "sessions"
  , ovSel   = 0
  , ovKind  = OverlaySessions cur ss
  }

-- | A model overlay; selection starts on the current model if present.
modelsOverlay :: ModelId -> [ModelId] -> Overlay
modelsOverlay cur ms = Overlay
  { ovTitle = "model"
  , ovSel   = fromMaybe 0 (elemIndex cur ms)
  , ovKind  = OverlayModels cur ms
  }

-- | The static help overlay.
helpOverlay :: Overlay
helpOverlay = Overlay
  { ovTitle = "help"
  , ovSel   = 0
  , ovKind  = OverlayHelp helpLines
  }

-- | A picker over the discovered skills (local + MCP prompts).
skillsOverlay :: [Skill] -> Overlay
skillsOverlay ss = Overlay
  { ovTitle = "skills"
  , ovSel   = 0
  , ovKind  = OverlaySkills ss
  }

helpLines :: [Text]
helpLines =
  "commands:" : map commandRow commandCatalog
    <> [ ""
       , "keys:"
       , "  Enter      send / confirm"
       , "  Esc        close overlay / abort run"
       , "  Up/Down    move selection / scroll"
       , "  Tab        complete the highlighted command"
       , "  Ctrl-C     quit"
       ]
  where
    commandRow (_, name, desc) = "  " <> T.justifyLeft 9 ' ' name <> "  " <> desc
