{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP               #-}
module GhcModPluginSpec where

import           Control.Exception
import qualified Data.Map                            as Map
import qualified Data.Set                            as S
import           Haskell.Ide.Engine.Ghc
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.Plugin.GhcMod
import           Haskell.Ide.Engine.PluginUtils
import           System.Directory
import           TestUtils

import           Test.Hspec

-- ---------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "ghc-mod plugin" ghcmodSpec

-- ---------------------------------------------------------------------

testPlugins :: IdePlugins
testPlugins = mkIdePlugins [ghcmodDescriptor]

-- ---------------------------------------------------------------------

ghcmodSpec :: Spec
ghcmodSpec =
  describe "ghc-mod plugin commands(old plugin api)" $ do
    it "runs the check command" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "./FileWithWarning.hs"
      let act = setTypecheckedModule arg
          arg = filePathToUri fp
          res = IdeResultOk $
            (Map.singleton arg (S.singleton diag), [])
          diag = Diagnostic (Range (toPos (4,7))
                                   (toPos (4,8)))
                            (Just DsError)
                            Nothing
                            (Just "ghcmod")
                            "Variable not in scope: x"
                            Nothing

      runIGM testPlugins act `shouldReturn` res

-- ----------------------------------------------------------------------------

    it "runs the type command, find type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "HaReRename.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (5,9)) uri
          res = IdeResultOk
            [ (Range (toPos (5,9)) (toPos (5,10)), "Int")
            , (Range (toPos (5,1)) (toPos (5,14)), "Int -> Int")
            ]

      runIGM testPlugins act `shouldReturn` res
    it "runs the type command, find function type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "HaReRename.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (2,11)) uri
          res = IdeResultOk
            [ (Range (toPos (2, 8)) (toPos (2,16)), "String -> IO ()")
            , (Range (toPos (2, 1)) (toPos (2,24)), "IO ()")
            ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, no type at location" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "HaReRename.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (1,1)) uri
          res = IdeResultOk []
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, simple" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (6,16)) uri
          res = IdeResultOk
              [ (Range (toPos (6, 16)) (toPos (6,17)), "Int")
              , (Range (toPos (6, 1)) (toPos (7, 16)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, sum type pattern match, just" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (6,6)) uri
          res = IdeResultOk
              [ (Range (toPos (6, 6)) (toPos (6, 12)), "Maybe Int")
              , (Range (toPos (6, 5)) (toPos (6, 13)), "Maybe Int")
              , (Range (toPos (6, 1)) (toPos (7, 16)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, sum type pattern match, just value" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (6,11)) uri
          res = IdeResultOk
            [ (Range (toPos (6, 11)) (toPos (6, 12)), "Int")
            , (Range (toPos (6, 6)) (toPos (6, 12)), "Maybe Int")
            , (Range (toPos (6, 5)) (toPos (6, 13)), "Maybe Int")
            , (Range (toPos (6, 1)) (toPos (7, 16)), "Maybe Int -> Int")
            ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, sum type pattern match, nothing" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (7,5)) uri
          res = IdeResultOk
              [ (Range (toPos (7, 5)) (toPos (7, 12)), "Maybe Int")
              , (Range (toPos (6, 1)) (toPos (7, 16)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, sum type pattern match, nothing, literal" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (7,15)) uri
          res = IdeResultOk
              [ (Range (toPos (7, 15)) (toPos (7, 16)), "Int")
              , (Range (toPos (6, 1)) (toPos (7, 16)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, variable matching" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (10,5)) uri
          res = IdeResultOk
              [ (Range (toPos (10, 5)) (toPos (10, 6)), "Maybe Int")
              , (Range (toPos (10, 1)) (toPos (12, 17)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, case expr" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (10,14)) uri
          res = IdeResultOk
              [ (Range (toPos (10, 14)) (toPos (10, 15)), "Maybe Int")
              , (Range (toPos (10, 9)) (toPos (12, 17)), "Maybe Int -> Int")
              , (Range (toPos (10, 1)) (toPos (12, 17)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, case expr match, just" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (11,5)) uri
          res = IdeResultOk
              [ (Range (toPos (11, 5)) (toPos (11, 11)), "Maybe Int")
              , (Range (toPos (10, 9)) (toPos (12, 17)), "Maybe Int -> Int")
              , (Range (toPos (10, 1)) (toPos (12, 17)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, case expr match, just value" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (11,10)) uri
          res = IdeResultOk
              [ (Range (toPos (11, 10)) (toPos (11, 11)), "Int")
              , (Range (toPos (11, 5)) (toPos (11, 11)), "Maybe Int")
              , (Range (toPos (10, 9)) (toPos (12, 17)), "Maybe Int -> Int")
              , (Range (toPos (10, 1)) (toPos (12, 17)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, infix operator" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (11,17)) uri
          res = IdeResultOk
              [ (Range (toPos (11, 17)) (toPos (11, 18)), "Int -> Int -> Int")
              , (Range (toPos (10, 9)) (toPos (12, 17)), "Maybe Int -> Int")
              , (Range (toPos (10, 1)) (toPos (12, 17)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, case expr match, nothing" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (12,5)) uri
          res = IdeResultOk
              [ (Range (toPos (12, 5)) (toPos (12, 12)), "Maybe Int")
              , (Range (toPos (10, 9)) (toPos (12, 17)), "Maybe Int -> Int")
              , (Range (toPos (10, 1)) (toPos (12, 17)), "Maybe Int -> Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, do bind expr result " $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (16,5)) uri
          res = IdeResultOk
              [ (Range (toPos (16, 5)) (toPos (16, 6)), "Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, do bind expr" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (16,10)) uri
          res = IdeResultOk
              [ (Range (toPos (16, 10)) (toPos (16, 11)), "Maybe Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, let binding function, return func" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (17,13)) uri
          res = IdeResultOk
              [ (Range (toPos (17, 13)) (toPos (17, 19)), "Int -> Maybe Int")
              , (Range (toPos (17, 9)) (toPos (17, 28)), "Maybe Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, let binding function, return param" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (17,21)) uri
          res = IdeResultOk
              [ (Range (toPos (17, 21)) (toPos (17, 22)), "Int")
              , (Range (toPos (17, 9)) (toPos (17, 28)), "Maybe Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, let binding function, function type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (17,9)) uri
          res = IdeResultOk
              [ (Range (toPos (17, 9)) (toPos (17, 28)), "Maybe Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, do expr, function type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (18,10)) uri
          res = IdeResultOk
              [ (Range (toPos (18, 10)) (toPos (18, 11)), "Maybe Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, let binding function, do expr bind for local func" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (18,5)) uri
          res = IdeResultOk
              [ (Range (toPos (18, 5)) (toPos (18, 6)), "Int")
              , (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, function type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (15,5)) uri
          res = IdeResultOk
              [ (Range (toPos (15, 1)) (toPos (19, 19)), "Maybe Int -> Maybe Int")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, function parameter" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (22,10)) uri
          res = IdeResultOk
              [ (Range (toPos (22, 10)) (toPos (22, 11)), "a -> a")
              , (Range (toPos (22, 1)) (toPos (22, 19)), "(a -> a) -> a -> a")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, function composition" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (25,26)) uri
          res = IdeResultOk
              [ (Range (toPos (25, 26)) (toPos (25, 27)), "(b -> c) -> (a -> b) -> a -> c")
              , (Range (toPos (25, 20)) (toPos (25, 29)), "a -> c")
              , (Range (toPos (25, 1)) (toPos (25, 34)), "(b -> c) -> (a -> b) -> a -> c")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, let binding, function composition" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (25,20)) uri
          res = IdeResultOk
              [ (Range (toPos (25, 20)) (toPos (25, 29)), "a -> c")
              , (Range (toPos (25, 1)) (toPos (25, 34)), "(b -> c) -> (a -> b) -> a -> c")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, let binding, type of function" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (25,33)) uri
          res = IdeResultOk
              [ (Range (toPos (25, 33)) (toPos (25, 34)), "a -> c")
              , (Range (toPos (25, 1)) (toPos (25, 34)), "(b -> c) -> (a -> b) -> a -> c")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, function type composition" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (25,5)) uri
          res = IdeResultOk
              [ (Range (toPos (25, 1)) (toPos (25, 34)), "(b -> c) -> (a -> b) -> a -> c")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, infix operator" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (28,25)) uri
          res = IdeResultOk
              [ (Range (toPos (28, 25)) (toPos (28, 28)), "(a -> b) -> IO a -> IO b")
              , (Range (toPos (28, 1)) (toPos (28, 35)), "(a -> b) -> IO a -> IO b")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, constructor" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (31,7)) uri
          res = IdeResultOk
              [ -- (Range (toPos (31, 7)) (toPos (31, 12)), "Int -> Test")
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, deriving clause Show type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (33,15)) uri
          res = IdeResultOk
              [ (Range (toPos (33, 15)) (toPos (33, 19)), "(Int -> Test -> ShowS) -> (Test -> String) -> ([Test] -> ShowS) -> Show Test")
              , (Range (toPos (33, 15)) (toPos (33, 19)), "Int -> Test -> ShowS")
              , (Range (toPos (33, 15)) (toPos (33, 19)), "Test -> String")
              , (Range (toPos (33, 15)) (toPos (33, 19)), "[Test] -> ShowS")
              , (Range (toPos (33, 15)) (toPos (33, 19)), "Int -> Test -> ShowS")
#if (defined(MIN_VERSION_GLASGOW_HASKELL) && (MIN_VERSION_GLASGOW_HASKELL(8,4,0,0)))
#else
              , (Range (toPos (33, 15)) (toPos (33, 19)), "[Test] -> ShowS")
#endif
              ]
      runIGM testPlugins act `shouldReturn` res

    it "runs the type command, deriving clause Eq type" $ withCurrentDirectory "./test/testdata" $ do
      fp <- makeAbsolute "Types.hs"
      let uri = filePathToUri fp
          act = do
            _ <- setTypecheckedModule uri
            liftToGhc $ newTypeCmd (toPos (33,21)) uri
          res = IdeResultOk
              [ (Range (toPos (33, 21)) (toPos (33, 23)), "(Test -> Test -> Bool) -> (Test -> Test -> Bool) -> Eq Test")
              , (Range (toPos (33, 21)) (toPos (33, 23)), "Test -> Test -> Bool")
              , (Range (toPos (33, 21)) (toPos (33, 23)), "Test -> Test -> Bool")
              , (Range (toPos (33, 21)) (toPos (33, 23)), "Test -> Test -> Bool")
#if (defined(MIN_VERSION_GLASGOW_HASKELL) && (MIN_VERSION_GLASGOW_HASKELL(8,4,0,0)))
#else
              , (Range (toPos (33, 21)) (toPos (33, 23)), "Test -> Test -> Bool")
#endif
              ]
      runIGM testPlugins act `shouldReturn` res

-- ----------------------------------------------------------------------------
    it "runs the type command with an absolute path from another folder, correct params" $ do
      fp <- makeAbsolute "./test/testdata/HaReRename.hs"
      cd <- getCurrentDirectory
      cd2 <- getHomeDirectory
      bracket (setCurrentDirectory cd2)
              (\_->setCurrentDirectory cd)
              $ \_-> do
        let uri = filePathToUri fp
        let act = do
              _ <- setTypecheckedModule uri
              liftToGhc $ newTypeCmd (toPos (5,9)) uri
        let res = IdeResultOk
              [(Range (toPos (5,9)) (toPos (5,10)), "Int")
              , (Range (toPos (5,1)) (toPos (5,14)), "Int -> Int")
              ]
        runIGM testPlugins act `shouldReturn` res
