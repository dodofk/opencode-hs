module OpenCode.TUI.OverlaySpec (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.Text as T
import Test.Hspec

import OpenCode.TUI.Overlay
  ( helpOverlay, modelsOverlay, overlayCount, overlayLabels, overlayMove
  , overlaySelected, sessionsOverlay )
import OpenCode.TUI.Command (commandCatalog)
import OpenCode.TUI.Types (Overlay (..))
import OpenCode.Types (ModelId (..), ProviderId (..), Session (..), SessionId (..))

spec :: Spec
spec = do
  describe "overlayMove (clamped navigation)" $ do
    let ov = modelsOverlay m1 [m1, m2, m3]   -- 3 rows, sel starts at 0

    it "moves down within bounds" $
      ovSel (overlayMove 1 ov) `shouldBe` 1

    it "clamps at the bottom" $
      ovSel (overlayMove 99 ov) `shouldBe` 2

    it "clamps at the top" $
      ovSel (overlayMove (-99) ov) `shouldBe` 0

    it "is a no-op on an empty overlay" $ do
      let empty = sessionsOverlay (SessionId "x") []
      ovSel (overlayMove 1 empty) `shouldBe` 0
      overlaySelected empty `shouldBe` Nothing

  describe "modelsOverlay" $
    it "preselects the current model" $
      ovSel (modelsOverlay m2 [m1, m2, m3]) `shouldBe` 1

  describe "overlayLabels" $ do
    it "marks the current model with a leading *" $
      overlayLabels (ovKind (modelsOverlay m2 [m1, m2]))
        `shouldBe` ["  openai:gpt-4o", "* anthropic:claude-opus-4-5"]

    it "marks the current session and counts rows" $ do
      let ov = sessionsOverlay (sessionId s2) [s1, s2]
      overlayCount (ovKind ov) `shouldBe` 2
      overlayLabels (ovKind ov) `shouldBe`
        ["  one  2026-06-01 00:00", "* two  2026-06-01 00:00"]

  describe "helpOverlay / catalog consistency" $
    it "lists every catalog command name in the help rows" $ do
      let rows  = overlayLabels (ovKind helpOverlay)
          names = [ n | (_, n, _) <- commandCatalog ]
      all (\n -> any (n `T.isInfixOf`) rows) names `shouldBe` True
  where
    m1 = ModelId OpenAI "gpt-4o"
    m2 = ModelId Anthropic "claude-opus-4-5"
    m3 = ModelId MiniMax "MiniMax-M3"
    s1 = Session (SessionId "s1") "one" m1 t0
    s2 = Session (SessionId "s2") "two" m2 t0
    t0 = UTCTime (fromGregorian 2026 6 1) 0
