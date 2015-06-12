-- | This module defines how the SoH editor and controls are rendered.
module View (renderControls, renderEditor) where

import qualified Ace
import Import
import Model (switchTab)
import React.IFrame
import TermJs
import View.Build
import View.Console
import View.Docs
import View.TypeInfo
import PosMap (handleChange, selectionToSpan)
import Model (runQuery, runCode)
import Control.Lens.Extras (is)

renderControls
  :: UComponent TermJs
  -> UComponent IFrame
  -> State
  -> React ()
renderControls termjs iframe state = do
  let status = state ^. stateStatus
  case status of
    InitialStatus -> return ()
    _ -> do
      class_ "soh-visible"
      -- Set the position of the controls.
      div_ $ do
        class_ "controls-bar"
        renderTab state BuildTab $ text (buildStatusText status)
        renderTab state ConsoleTab "Console"
        renderTab state DocsTab "Docs"
        -- renderTab state WebTab "Web"
      renderTabContent state BuildTab $ buildTab status
      renderTabContent state ConsoleTab $ consoleTab termjs
      renderTabContent state DocsTab $ docsTab state
      -- renderTabContent state WebTab $ buildIFrame iframe stateWeb Nothing

--------------------------------------------------------------------------------
-- Editor

renderEditor
  :: UComponent Ace.Editor
  -> UComponent TermJs
  -> UComponent IFrame
  -> SnippetId
  -> JSString
  -> Bool
  -> State
  -> React ()
renderEditor ace termjs iframe sid initialValue inlineControls state = div_ $ do
  let isCurrent = currentSnippet state == Just sid
  class_ $ addWhen isCurrent "soh-current"
         $ addWhen (not inlineControls) "soh-remote-controls"
         $ "soh-snippet"
  buildUnmanaged ace (ixSnippet sid . snippetEditor) $ \stateVar q -> do
    editor <- Ace.makeEditor q
    Ace.setMaxLinesInfty editor
    Ace.setValue editor initialValue
    debounce 100 (handleSelectionChange stateVar sid) >>=
      Ace.onSelectionChange editor
    Ace.onChange editor (handleChange stateVar sid)
    return editor
  renderRunButton sid isCurrent (state ^. stateStatus)
  forM_ (join (state ^? ixSnippet sid . snippetTypeInfo)) $ \typs ->
    typePopup typs 300 100
  when (isCurrent && inlineControls) $ div_ $ do
    id_ "soh-controls"
    div_ $ renderControls termjs iframe state

handleSelectionChange :: TVar State -> SnippetId -> IO ()
handleSelectionChange stateVar sid = do
  -- Clear the old type info.
  setTVarIO stateVar (ixSnippet sid . snippetTypeInfo) Nothing
  -- Compute the source span of the query at the time of compilation.
  state <- readTVarIO stateVar
  selection <- Ace.getSelection =<< getEditor state sid
  case selectionToSpan state sid selection of
    -- FIXME: UI for this.
    Nothing -> putStrLn "No span for this query"
    Just ss -> runQuery stateVar sid (QueryInfo ss)

renderRunButton :: SnippetId -> Bool -> Status -> React ()
renderRunButton sid isCurrent s = div_ $ do
  let building = is _BuildRequested s || is _Building s
  class_ $ addWhen (building && isCurrent) "building"
         $ "run glyphicon"
  title_ "Compile and run code"
  onClick $ \_ state -> do
    editor <- readEditor state sid
    code <- Ace.getValue editor
    runCode state (BuildRequest sid [("main.hs", code)])

--------------------------------------------------------------------------------
-- Tabs

renderTab :: State -> Tab -> React () -> React ()
renderTab state tab f = div_ $ do
  class_ $
    addWhen (state ^. stateTab == tab) "tab-focused"
    ("tab " <> tabClass tab)
  onClick (\_ -> flip switchTab tab)
  f

renderTabContent :: State -> Tab -> React () -> React ()
renderTabContent state tab f = div_ $ do
  class_ $
    addWhen (state ^. stateTab == tab) "tab-content-focused"
    ("tab-content " <> tabClass tab <> "-content")
  f

tabClass :: Tab -> Text
tabClass BuildTab = "build-tab"
tabClass ConsoleTab = "console-tab"
tabClass DocsTab = "docs-tab"
tabClass WebTab = "web-tab"