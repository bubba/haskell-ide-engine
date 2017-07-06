{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE BangPatterns          #-}

module Haskell.Ide.HaRePlugin where

import           Control.Lens                                 ((^.))
import           Control.Monad.State
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either
import           Data.Aeson
import           Data.Either
import           Data.Foldable
import qualified Data.Map                                     as Map
import           Data.Monoid
import           Data.Maybe
import qualified Data.Text                                    as T
import qualified Data.Text.IO                                 as T
import           Data.Typeable
import           Exception
import           GHC
import qualified GhcMod.Error                                 as GM
import qualified GhcMod.Monad                                 as GM
import qualified GhcMod.Utils                                 as GM
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.SemanticTypes
import           Language.Haskell.GHC.ExactPrint.Print
import qualified Language.Haskell.LSP.TH.DataTypesJSON        as J
import           Language.Haskell.Refact.API
import           Language.Haskell.Refact.HaRe
import           Language.Haskell.Refact.Utils.Monad
import           Language.Haskell.Refact.Utils.MonadFunctions
import           Name
import           Packages
import           Module
import           Haskell.Ide.GhcModPlugin (setTypecheckedModule)
-- ---------------------------------------------------------------------

hareDescriptor :: TaggedPluginDescriptor _
hareDescriptor = PluginDescriptor
  {
    pdUIShortName = "HaRe"
  , pdUIOverview = "A Haskell 2010 refactoring tool. HaRe supports the full "
              <> "Haskell 2010 standard, through making use of the GHC API.  HaRe attempts to "
              <> "operate in a safe way, by first writing new files with proposed changes, and "
              <> "only swapping these with the originals when the change is accepted. "
    , pdCommands =
        buildCommand demoteCmd (Proxy :: Proxy "demote") "Move a definition one level down"
                    [".hs"] (SCtxPoint :& RNil) RNil SaveAll

      :& buildCommand dupdefCmd (Proxy :: Proxy "dupdef") "Duplicate a definition"
                     [".hs"] (SCtxPoint :& RNil)
                     (  SParamDesc (Proxy :: Proxy "name") (Proxy :: Proxy "the new name") SPtText SRequired
                     :& RNil) SaveAll

      :& buildCommand iftocaseCmd (Proxy :: Proxy "iftocase") "Converts an if statement to a case statement"
                     [".hs"] (SCtxRegion :& RNil) RNil SaveAll

      :& buildCommand liftonelevelCmd (Proxy :: Proxy "liftonelevel") "Move a definition one level up from where it is now"
                     [".hs"] (SCtxPoint :& RNil) RNil SaveAll

      :& buildCommand lifttotoplevelCmd (Proxy :: Proxy "lifttotoplevel") "Move a definition to the top level from where it is now"
                     [".hs"] (SCtxPoint :& RNil) RNil SaveAll

      :& buildCommand renameCmd (Proxy :: Proxy "rename") "rename a variable or type"
                     [".hs"] (SCtxPoint :& RNil)
                     (  SParamDesc (Proxy :: Proxy "name") (Proxy :: Proxy "the new name") SPtText SRequired
                     :& RNil) SaveAll

      :& buildCommand deleteDefCmd (Proxy :: Proxy "deletedef") "Delete a definition"
                    [".hs"] (SCtxPoint :& RNil) RNil SaveAll

      :& buildCommand genApplicativeCommand (Proxy :: Proxy "genapplicative") "Generalise a monadic function to use applicative"
                    [".hs"] (SCtxPoint :& RNil) RNil SaveAll

      :& RNil
  , pdExposedServices = []
  , pdUsedServices    = []
  }

-- ---------------------------------------------------------------------

demoteCmd :: CommandFunc WorkspaceEdit
demoteCmd  = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& RNil) ->
      demoteCmd' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos)

demoteCmd' :: TextDocumentPositionParams -> IdeM (IdeResponse WorkspaceEdit)
demoteCmd' (TextDocumentPositionParams tdi pos) =
  pluginGetFile "demote: " (tdi ^. J.uri) $ \file -> do
    runHareCommand "demote" (compDemote file (unPos pos))

-- compDemote :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

dupdefCmd :: CommandFunc WorkspaceEdit
dupdefCmd = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& IdText "name" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& ParamText name :& RNil) ->
      dupdefCmd' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos) name

dupdefCmd' :: TextDocumentPositionParams -> T.Text -> IdeM (IdeResponse WorkspaceEdit)
dupdefCmd' (TextDocumentPositionParams tdi pos) name =
  pluginGetFile "dupdef: " (tdi ^. J.uri) $ \file -> do
    runHareCommand  "dupdef" (compDuplicateDef file (T.unpack name) (unPos pos))

-- compDuplicateDef :: FilePath -> String -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

iftocaseCmd :: CommandFunc WorkspaceEdit
iftocaseCmd = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& IdPos "end_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos startPos :& ParamPos endPos :& RNil) ->
      iftocaseCmd' (Location uri (Range startPos endPos))

iftocaseCmd' :: Location -> IdeM (IdeResponse WorkspaceEdit)
iftocaseCmd' (Location uri (Range startPos endPos)) =
  pluginGetFile "iftocase: " uri $ \file -> do
    runHareCommand "iftocase" (compIfToCase file (unPos startPos) (unPos endPos))

-- compIfToCase :: FilePath -> SimpPos -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

liftonelevelCmd :: CommandFunc WorkspaceEdit
liftonelevelCmd = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& RNil) ->
      liftonelevelCmd' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos)

liftonelevelCmd' :: TextDocumentPositionParams -> IdeM (IdeResponse WorkspaceEdit)
liftonelevelCmd' (TextDocumentPositionParams tdi pos) =
  pluginGetFile "liftonelevelCmd: " (tdi ^. J.uri) $ \file -> do
    runHareCommand "liftonelevel" (compLiftOneLevel file (unPos pos))

-- compLiftOneLevel :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

lifttotoplevelCmd :: CommandFunc WorkspaceEdit
lifttotoplevelCmd = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& RNil) ->
      lifttotoplevelCmd' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos)

lifttotoplevelCmd' :: TextDocumentPositionParams -> IdeM (IdeResponse WorkspaceEdit)
lifttotoplevelCmd' (TextDocumentPositionParams tdi pos) =
  pluginGetFile "lifttotoplevelCmd: " (tdi ^. J.uri) $ \file -> do
    runHareCommand "lifttotoplevel" (compLiftToTopLevel file (unPos pos))

-- compLiftToTopLevel :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

renameCmd :: CommandFunc WorkspaceEdit
renameCmd = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& IdText "name" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& ParamText name :& RNil) ->
      renameCmd' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos) name

renameCmd' :: TextDocumentPositionParams -> T.Text -> IdeM (IdeResponse WorkspaceEdit)
renameCmd' (TextDocumentPositionParams tdi pos) name =
  pluginGetFile "rename: " (tdi ^. J.uri) $ \file -> do
      runHareCommand "rename" (compRename file (T.unpack name) (unPos pos))

-- compRename :: FilePath -> String -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

deleteDefCmd :: CommandFunc WorkspaceEdit
deleteDefCmd  = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& RNil) ->
      deleteDefCmd' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos)

deleteDefCmd' :: TextDocumentPositionParams -> IdeM (IdeResponse WorkspaceEdit)
deleteDefCmd' (TextDocumentPositionParams tdi pos) =
  pluginGetFile "deletedef: " (tdi ^. J.uri) $ \file -> do
      runHareCommand "deltetedef" (compDeleteDef file (unPos pos))

-- compDeleteDef ::FilePath -> SimpPos -> RefactGhc [ApplyRefacResult]

-- ---------------------------------------------------------------------

genApplicativeCommand :: CommandFunc WorkspaceEdit
genApplicativeCommand  = CmdSync $ \_ctxs req ->
  case getParams (IdFile "file" :& IdPos "start_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& RNil) ->
      genApplicativeCommand' (TextDocumentPositionParams (TextDocumentIdentifier uri) pos)

genApplicativeCommand' :: TextDocumentPositionParams -> IdeM (IdeResponse WorkspaceEdit)
genApplicativeCommand' (TextDocumentPositionParams tdi pos) =
  pluginGetFile "genapplicative: " (tdi ^. J.uri) $ \file -> do
      runHareCommand "genapplicative" (compGenApplicative file (unPos pos))


-- ---------------------------------------------------------------------

getRefactorResult :: [ApplyRefacResult] -> [(FilePath,T.Text)]
getRefactorResult = map getNewFile . filter fileModified
  where fileModified ((_,m),_) = m == RefacModified
        getNewFile ((file,_),(ann, parsed)) = (file, T.pack $ exactPrint parsed ann)

makeRefactorResult :: [(FilePath,T.Text)] -> IdeM WorkspaceEdit
makeRefactorResult changedFiles = do
  let
    diffOne :: (FilePath, T.Text) -> IdeM WorkspaceEdit
    diffOne (fp, newText) = do
      origText <- GM.withMappedFile fp $ liftIO . T.readFile
      return $ diffText (filePathToUri fp, origText) newText
  diffs <- mapM diffOne changedFiles
  return $ fold diffs

-- ---------------------------------------------------------------------
nonExistentCacheErr :: String -> IdeResponse a
nonExistentCacheErr meth =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": \"" <> "module not loaded" <> "\"")
             Null

invalidCursorErr :: String -> IdeResponse a
invalidCursorErr meth =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": \"" <> "Invalid cursor position" <> "\"")
             Null

-- ---------------------------------------------------------------------

data NameMapData = NMD
  { nameMap        :: !(Map.Map SrcSpan Name)
  , inverseNameMap ::  Map.Map Name [SrcSpan]
  } deriving (Typeable)

invert :: (Ord k, Ord v) => Map.Map k v -> Map.Map v [k]
invert m = Map.fromListWith (++) [(v,[k]) | (k,v) <- Map.toList m]

instance ModuleCache NameMapData where
  cacheDataProducer cm = pure $ NMD nm inm
    where nm  = initRdrNameMap $ tcMod cm
          inm = invert nm

-- ---------------------------------------------------------------------

getSymbols :: Uri -> IdeM (IdeResponse [J.SymbolInformation])
getSymbols uri = do
    mcm <- getCachedModule uri
    rfm <- GM.mkRevRedirMapFunc
    case mcm of
      Nothing -> return $ IdeResponseOk []
      Just cm -> do
          let tm = tcMod cm
              hsMod = unLoc $ pm_parsed_source $ tm_parsed_module tm
              imports = hsmodImports hsMod
              imps  = concatMap (goImport . unLoc) imports
              decls = concatMap (go . unLoc) $ hsmodDecls hsMod
              s x = T.pack . showGhc <$> x

              go :: HsDecl RdrName -> [(J.SymbolKind,Located T.Text,Maybe T.Text)]
              go (TyClD (FamDecl (FamilyDecl _ n _ _ _))) = pure (J.SkClass,s n, Nothing)
              go (TyClD (SynDecl n _ _ _)) = pure (J.SkClass,s n,Nothing)
              go (TyClD (DataDecl n _ (HsDataDefn _ _ _ _ cons _) _ _)) =
                (J.SkClass, s n, Nothing) : concatMap (processCon (unLoc $ s n) . unLoc) cons
              go (TyClD (ClassDecl _ n _ _ sigs _ fams _ _ _)) =
                (J.SkInterface, sn, Nothing) :
                      concatMap (processSig (unLoc sn) . unLoc) sigs
                  ++  concatMap (map setCnt . go . TyClD . FamDecl . unLoc) fams
                where sn = s n
                      setCnt (k,n',_) = (k,n',Just (unLoc sn))
              go (ValD (FunBind ln _ _ _ _)) = pure (J.SkFunction, s ln, Nothing)
              go (ValD (PatBind p  _ _ _ _)) =
                map (\n ->(J.SkMethod,s n, Nothing)) $ hsNamessRdr p
              go (ForD (ForeignImport n _ _ _)) = pure (J.SkFunction, s n, Nothing)
              go _ = []

              processSig :: T.Text
                         -> Sig RdrName
                         -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              processSig cnt (ClassOpSig False names _) =
                map (\n ->(J.SkMethod,s n, Just cnt)) names
              processSig _ _ = []

              processCon :: T.Text
                         -> ConDecl RdrName
                         -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              processCon cnt (ConDeclGADT names _ _) =
                map (\n -> (J.SkConstructor, s n, Just cnt)) names
              processCon cnt (ConDeclH98 name _ _ dets _) =
                (J.SkConstructor, sn, Just cnt) : xs
                where
                  sn = s name
                  xs = case dets of
                    RecCon (L _ rs) -> concatMap (map (f . rdrNameFieldOcc . unLoc)
                                                 . cd_fld_names
                                                 . unLoc) rs
                                         where f ln = (J.SkField, s ln, Just (unLoc sn))
                    _ -> []

              goImport :: ImportDecl RdrName -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              goImport (ImportDecl _ lmn@(L l _) _ _ _ _ _ as meis) = a ++ xs
                where
                  im = (J.SkModule, lsmn, Nothing)
                  lsmn = s lmn
                  smn = unLoc lsmn
                  a = case as of
                            Just a' -> [(J.SkNamespace, s (L l a'), Just smn)]
                            Nothing -> [im]
                  xs = case meis of
                         Just (False, eis) -> concatMap (f . unLoc) (unLoc eis)
                         _ -> []
                  f (IEVar n) = pure (J.SkFunction, s n, Just smn)
                  f (IEThingAbs n) = pure (J.SkClass, s n, Just smn)
                  f (IEThingAll n) = pure (J.SkClass, s n, Just smn)
                  f (IEThingWith n _ vars fields) =
                    let sn = s n in
                    (J.SkClass, sn, Just smn) :
                         map (\n' -> (J.SkFunction, s n', Just (unLoc sn))) vars
                      ++ map (\f' -> (J.SkField   , s f', Just (unLoc sn))) fields
                  f _ = []

              declsToSymbolInf :: (J.SymbolKind, Located T.Text, Maybe T.Text)
                               -> IdeM (Either T.Text J.SymbolInformation)
              declsToSymbolInf (kind, L l nameText, cnt) = do
                eloc <- srcSpan2Loc rfm l
                case eloc of
                  Left x -> return $ Left x
                  Right loc -> return $ Right $ J.SymbolInformation nameText kind loc cnt
          symInfs <- mapM declsToSymbolInf (imps ++ decls)
          return $ IdeResponseOk $ rights symInfs
-- ---------------------------------------------------------------------

getSymbolAtPoint :: Uri -> Position -> IdeM (IdeResponse (Maybe (Located Name)))
getSymbolAtPoint file pos = do
  let noCache = return $ nonExistentCacheErr "getSymbolAtPoint"
  withCachedModuleAndData file noCache $
    \cm NMD{nameMap} ->
      return $ IdeResponseOk
             $ symbolFromTypecheckedModule nameMap (tcMod cm) =<< newPosToOld cm pos

symbolFromTypecheckedModule
  :: Map.Map SrcSpan Name
  -> TypecheckedModule
  -> Position
  -> Maybe (Located Name)
symbolFromTypecheckedModule nm tc pos = do
  pn@(L l _) <- locToRdrName (unPos pos) parsed
  return $ L l $ rdrName2NamePure nm pn
  where parsed = pm_parsed_source $ tm_parsed_module tc

-- ---------------------------------------------------------------------

getReferencesInDoc :: Uri -> Position -> IdeM (IdeResponse [J.DocumentHighlight])
getReferencesInDoc uri pos = do
  let noCache = return $ nonExistentCacheErr "getReferencesInDoc"
  withCachedModuleAndData uri noCache $
    \cm NMD{nameMap, inverseNameMap} -> runEitherT $ do
      let tc = tcMod cm
          parsed = pm_parsed_source $ tm_parsed_module tc
          mpos = newPosToOld cm pos
      case mpos of
        Nothing -> return []
        Just pos' ->
          case locToRdrName (unPos pos') parsed of
            Nothing -> hoistEither $ invalidCursorErr "hare:getReferencesInDoc"
            Just pn -> do
              let name = rdrName2NamePure nameMap pn
                  usages = Map.lookup name inverseNameMap
                  ranges = maybe [] (rights . map srcSpan2Range) usages
                  defn = srcSpan2Range $ nameSrcSpan name
                  makeDocHighlight r = do
                    let kind = if Right r == defn then J.HkWrite else J.HkRead
                    r' <- oldRangeToNew cm r
                    return $ J.DocumentHighlight r' (Just kind)
                  highlights = mapMaybe makeDocHighlight ranges
              return highlights

-- ---------------------------------------------------------------------

showQualName :: Located Name -> T.Text
showQualName = T.pack . showGhcQual

showName :: Located Name -> T.Text
showName = T.pack . showGhc

getModule :: DynFlags -> Located Name -> Maybe (Maybe T.Text,T.Text)
getModule df (L _ n) = do
  m <- nameModule_maybe n
  let uid = moduleUnitId m
  let pkg = showGhc . packageName <$> lookupPackage df uid
  return (T.pack <$> pkg, T.pack $ moduleNameString $ moduleName m)

-- ---------------------------------------------------------------------

getNewNames :: GhcMonad m => Name -> m [Name]
getNewNames old = do
  let eqModules (Module pk1 mn1) (Module pk2 mn2) = mn1 == mn2 && pk1 == pk2
  gnames <- GHC.getNamesInScope
  let clientModule = GHC.nameModule old
  let clientInscopes = filter (\n -> eqModules clientModule (GHC.nameModule n)) gnames
  let newNames = filter (\n -> showGhcQual n == showGhcQual old) clientInscopes
  return newNames

findDef :: Uri -> Position -> IdeM (IdeResponse Location)
findDef file pos = do
  rfm <- GM.mkRevRedirMapFunc
  let noCache = return $ nonExistentCacheErr "hare:findDef"
  withCachedModuleAndData file noCache $
    \cm NMD{nameMap} -> do
      let tc = tcMod cm
      case symbolFromTypecheckedModule nameMap tc =<< newPosToOld cm pos of
        Nothing -> return $ invalidCursorErr "hare:findDef"
        Just pn -> do
          let n = unLoc pn
          res <- srcSpan2Loc rfm $ nameSrcSpan n
          case res of
            Right l@(J.Location uri range) ->
              case oldRangeToNew cm range of
                Just r -> return $ IdeResponseOk (J.Location uri r)
                Nothing -> return $ IdeResponseOk l
            Left x -> do
              let failure = pure (IdeResponseFail
                                    (IdeError PluginError
                                              ("hare:findDef" <> ": \"" <> x <> "\"")
                                              Null))
              case nameModule_maybe n of
                Just m -> do
                  let mName = moduleName m
                  b <- GM.unGmlT $ isLoaded mName
                  if b then do
                    mLoc <- GM.unGmlT $ ms_location <$> getModSummary mName
                    case ml_hs_file mLoc of
                      Just fp -> do
                        let uri = filePathToUri fp
                        mcm' <- getCachedModule uri
                        cm' <- case mcm' of
                          Just cmdl -> return cmdl
                          Nothing -> do
                            _ <- setTypecheckedModule uri
                            fromJust <$> getCachedModule uri
                        let modSum = pm_mod_summary $ tm_parsed_module $ tcMod cm'
                        newNames <- GM.unGmlT $ do
                          setGhcContext modSum
                          getNewNames n
                        eithers <- mapM (srcSpan2Loc rfm . nameSrcSpan) newNames
                        case rights eithers of
                          (l:_) -> return $ IdeResponseOk l
                          []    -> failure
                      Nothing -> failure
                    else failure
                Nothing -> failure

-- ---------------------------------------------------------------------


runHareCommand :: String -> RefactGhc [ApplyRefacResult]
                 -> IdeM (IdeResponse WorkspaceEdit)
runHareCommand name cmd = do
     eitherRes <- runHareCommand' cmd
     case eitherRes of
       Left err ->
         pure (IdeResponseFail
                 (IdeError PluginError
                           (T.pack $ name <> ": \"" <> err <> "\"")
                           Null))
       Right res -> do
            let changes = getRefactorResult res
            refactRes <- makeRefactorResult changes
            pure (IdeResponseOk refactRes)

-- ---------------------------------------------------------------------

runHareCommand' :: RefactGhc a
                 -> IdeM (Either String a)
runHareCommand' cmd =
  do let initialState =
           -- TODO: Make this a command line flag
           RefSt {rsSettings = defaultSettings
           -- RefSt {rsSettings = logSettings
                 ,rsUniqState = 1
                 ,rsSrcSpanCol = 1
                 ,rsFlags = RefFlags False
                 ,rsStorage = StorageNone
                 ,rsCurrentTarget = Nothing
                 ,rsModule = Nothing}
     let cmd' = unRefactGhc cmd
         embeddedCmd =
           GM.unGmlT $
           hoist (liftIO . flip evalStateT initialState)
                 (GM.GmlT cmd')
         handlers
           :: Applicative m
           => [GM.GHandler m (Either String a)]
         handlers =
           [GM.GHandler (\(ErrorCall e) -> pure (Left e))
           ,GM.GHandler (\(err :: GM.GhcModError) -> pure (Left (show err)))]
     fmap Right embeddedCmd `GM.gcatches` handlers

-- ---------------------------------------------------------------------
-- | This is like hoist from the mmorph package, but build on
-- `MonadTransControl` since we don’t have an `MFunctor` instance.
hoist
  :: (MonadTransControl t,Monad (t m'),Monad m',Monad m)
  => (forall b. m b -> m' b) -> t m a -> t m' a
hoist f a =
  liftWith (\run ->
              let b = run a
                  c = f b
              in pure c) >>=
  restoreT
