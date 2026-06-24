module OpenCode.Net.HttpSpec (spec) where

import Test.Hspec

import OpenCode.Net.Http
import OpenCode.Net.HttpMock

spec :: Spec
spec = do
  describe "defaultRequest" $ do
    it "builds a GET request with empty headers and no body" $ do
      let r = defaultRequest "https://example.com"
      hrMethod r `shouldBe` "GET"
      hrUrl r `shouldBe` "https://example.com"
      hrHeaders r `shouldBe` []
      hrBody r `shouldBe` Nothing

  describe "withHeader" $ do
    it "appends a header" $
      hrHeaders (withHeader "Accept" "json" (defaultRequest "u"))
        `shouldBe` [("Accept", "json")]

    it "appends multiple headers in order" $
      hrHeaders
        (withHeader "B" "2" (withHeader "A" "1" (defaultRequest "u")))
        `shouldBe` [("A", "1"), ("B", "2")]

  describe "withQuery" $ do
    it "appends a percent-encoded query param with ?" $
      hrUrl (withQuery "q" "a b" (defaultRequest "https://x.com/p"))
        `shouldBe` "https://x.com/p?q=a%20b"

    it "appends with & when a query is already present" $
      hrUrl (withQuery "b" "2" (withQuery "a" "1" (defaultRequest "https://x.com/p")))
        `shouldBe` "https://x.com/p?a=1&b=2"

    it "percent-encodes reserved characters" $
      hrUrl (withQuery "q" "a&b=c" (defaultRequest "https://x.com/p"))
        `shouldBe` "https://x.com/p?q=a%26b%3Dc"

    it "leaves unreserved characters untouched" $
      hrUrl (withQuery "q" "AZaz09-_.~" (defaultRequest "https://x.com/p"))
        `shouldBe` "https://x.com/p?q=AZaz09-_.~"

  describe "withMethod / withBody" $ do
    it "sets the method" $
      hrMethod (withMethod "POST" (defaultRequest "u")) `shouldBe` "POST"

    it "sets the body" $
      hrBody (withBody "payload" (defaultRequest "u")) `shouldBe` Just "payload"

  describe "httpErrorStatus" $ do
    it "extracts the status from an HttpError" $
      httpErrorStatus (HttpError 404 "not found") `shouldBe` 404

    it "is 0 for transport failures" $
      httpErrorStatus (HttpError 0 "connection refused") `shouldBe` 0

  describe "runHttp (live)" $ do
    -- Live success is a manual smoke test (per spec); we only assert the
    -- transport-failure path here so CI never depends on DNS/HTTP working.
    it "returns Left with status 0 for an unresolvable host" $ do
      let req = defaultRequest "http://this-host-definitely-does-not-exist.invalid/"
      result <- runHttp req
      case result of
        Left err -> heStatus err `shouldBe` 0
        Right _  -> expectationFailure "expected transport failure, got a response"

  describe "mockBackend" $ do
    it "returns the matching response by URL substring" $ do
      let backend = mockBackend
            [ ( "example.com", Right "body-bytes" ) ]
          req = defaultRequest "https://example.com/page"
      result <- backend req
      result `shouldBe` Right "body-bytes"

    it "returns a 404 HttpError when no URL matches" $ do
      let backend = mockBackend []
          req = defaultRequest "https://example.com/"
      result <- backend req
      case result of
        Left err -> heStatus err `shouldBe` 404
        Right _  -> expectationFailure "expected 404, got a response"

    it "can return a canned HttpError (e.g. 401)" $ do
      let backend = mockBackend
            [ ( "api.example.com", Left (HttpError 401 "unauthorized") ) ]
          req = defaultRequest "https://api.example.com/resource"
      result <- backend req
      case result of
        Left err -> heStatus err `shouldBe` 401
        Right _  -> expectationFailure "expected 401, got a response"

    it "first match wins (ascending key order)" $ do
      let backend = mockBackend
            [ ( "api.example.com", Right "specific" )
            , ( "example.com",     Right "general" )
            ]
      -- "api.example.com" is the tighter substring; both match "api.example.com"
      result <- backend (defaultRequest "https://api.example.com/x")
      result `shouldBe` Right "specific"
