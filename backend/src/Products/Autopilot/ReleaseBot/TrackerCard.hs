{-# LANGUAGE OverloadedStrings #-}

-- | The Approve / Discard card in the thread of a release tracker's Xyne message — for every
-- backend release, whether the release bot or a person in SCC created it. It states what changes
-- (version, env/dhall diff, SQL) and its buttons disappear as soon as the release is approved or
-- discarded, from the card or from SCC.
module Products.Autopilot.ReleaseBot.TrackerCard
  ( postTrackerCard,
    closeTrackerCard,
  )
where

import Control.Monad (unless, void)
import Core.Environment (Flow)
import Core.Logging (logInfoG, logWarningG)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Products.Autopilot.DiffLink (toCommitId)
import Products.Autopilot.ProdRelease.Config (ProdReleaseConfig (..), RepoCfg (..), ServiceCfg (..), repoSlug)
import Products.Autopilot.ProdRelease.Github (CompareResult (..), compareFiles, resolveBaseSha)
import Products.Autopilot.Queries.ReleaseTracker qualified as RTQ
import Products.Autopilot.ReleaseBot.ConfigSource (loadBotConfig)
import Products.Autopilot.ReleaseBot.GithubAuth (githubTokenFlow)
import Products.Autopilot.ReleaseBot.PublicLink (requestIdOfGlobalId)
import Products.Autopilot.ReleaseBot.Sql (countStatements, sqlFromCompare, statementsFor)
import Products.Autopilot.ReleaseBot.Store (Req (..), dField, dText, getRequest)
import Products.Autopilot.ReleaseBot.Xyne qualified as X
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Products.Autopilot.Types.Storage.Schema (reLabel, rePayload)

-- | Post the card into the tracker message's thread and remember where it is.
postTrackerCard :: ReleaseTracker -> Text -> Text -> Text -> Flow ()
postTrackerCard t channel threadTs conversation = do
  facts <- trackerFacts t
  logInfoG ("[tracker-card] " <> releaseId t <> " facts: " <> T.intercalate " | " facts)
  let tid = releaseId t
      text =
        T.intercalate "\n" $
          [ "Release approval — " <> service t <> " (" <> env t <> ")",
            "Version: `" <> oldVersion t <> "` → `" <> newVersion t <> "`"
          ]
            ++ facts
            ++ ["Approving starts the rollout."]
  r <- X.postCard channel (Just conversation) text (X.flowCard text [("Approve and start rollout", X.trackerApproveVerb <> ":" <> tid, False), ("Discard release", X.trackerDiscardVerb <> ":" <> tid, True)])
  case r of
    Right (mid, inThread) | not (T.null mid) -> do
      RTQ.insertReleaseEvent tid "XYNE" "APPROVAL_CARD" (object ["channel" .= channel, "messageId" .= mid, "inThread" .= inThread])
      logInfoG ("[tracker-card] posted for " <> tid <> " message=" <> mid <> (if inThread then " (in thread)" else " (channel level)"))
    Right _ -> logWarningG ("[tracker-card] no message id returned for " <> tid)
    Left e -> logWarningG ("[tracker-card] could not post for " <> tid <> ": " <> e)

-- | Replace the card with plain text (no buttons). Once per tracker: the first caller wins, so
-- the click handler and the SCC-side notification cannot fight over the text.
closeTrackerCard :: Text -> Text -> Flow ()
closeTrackerCard tid outcome = do
  evs <- RTQ.listReleaseEventsByCategory tid "XYNE"
  let card = [rePayload e | e <- evs, reLabel e == "APPROVAL_CARD"]
      closed = any ((== "APPROVAL_CARD_CLOSED") . reLabel) evs
  case (card, closed) of
    (p : _, False)
      | Just ch <- dText "channel" p,
        Just mid <- dText "messageId" p -> do
          RTQ.insertReleaseEvent tid "XYNE" "APPROVAL_CARD_CLOSED" (object ["outcome" .= outcome])
          r <- X.updateCard ch mid outcome
          case r of
            Left e -> logWarningG ("[tracker-card] could not close card of " <> tid <> ": " <> e)
            Right () -> pure ()
    _ -> pure ()

-- | What the release changes besides the image: env/dhall and SQL (each answered yes / no).
trackerFacts :: ReleaseTracker -> Flow [Text]
trackerFacts t = do
  let overrideAttached = maybe False (\o -> T.strip o `notElem` ["", "null", "{}", "[]"]) (envOverrideData t)
      yn b = if b then "Yes" else "No"
  case globalId t >>= requestIdOfGlobalId of
    Nothing -> manualFacts t overrideAttached
    Just rid -> do
      mr <- getRequest rid
      pure $ case mr of
        Nothing -> ["Env / dhall diff: unknown (request not found)", "SQL change: unknown (request not found)"]
        Just r ->
          let d = rqData r
              svc = service t
              an = fromMaybe Null (dField "analysis" d)
              listOf k = case dField k an of Just (Array xs) -> V.toList xs; _ -> []
              has k v = case v of Object o -> KM.lookup (K.fromText k) o; _ -> Nothing
              isStr k want v = has k v == Just (String want)
              envChanged = not (null [() | e <- listOf "envChanges", isStr "service" svc e, isStr "state" "changed" e])
              dhallChanged = not (null [() | s <- listOf "services", isStr "service" svc s, Just (Array h) <- [has "dhallHits" s], not (V.null h)])
              cmChanged = not (null (listOf "configMaps"))
              sqlChanged = isJust (dText ("sql:" <> svc) d)
           in [ "Env / dhall diff: " <> yn (envChanged || dhallChanged || overrideAttached),
                "ConfigMap change in this request: " <> yn cmChanged,
                "SQL change: " <> yn sqlChanged <> (if sqlChanged then maybe "" (\l -> " — DB Manager request: " <> l) (dText "dbmRequest" d) else "")
              ]

-- | A release made by hand in SCC: look at the old...new diff ourselves, with the release bot's rules for the service.
manualFacts :: ReleaseTracker -> Bool -> Flow [Text]
manualFacts t overrideAttached = do
  cfg <- loadBotConfig
  let unknown why = ["Env / dhall diff: " <> (if overrideAttached then "Yes" else "unknown") <> " (" <> why <> ")", "SQL change: unknown (" <> why <> ")"]
  case cfg of
    Left _ -> pure (unknown "release bot config not available")
    Right pc ->
      case [(repo, svc) | repo <- prcRepos pc, svc <- rcServices repo, scService svc == service t] of
        [] -> pure (unknown "service is not set up in the release bot")
        ((repo, svc) : _) -> do
          tok <- githubTokenFlow
          case (tok, toCommitId (oldVersion t), toCommitId (newVersion t)) of
            (Left e, _, _) -> pure (unknown e)
            (_, Nothing, _) -> pure (unknown "old version is not a commit")
            (_, _, Nothing) -> pure (unknown "new version is not a commit")
            (Right token, Just o, Just n) -> do
              let slug = repoSlug repo
              base <- either (const o) id <$> resolveBaseSha token slug o
              headSha <- either (const n) id <$> resolveBaseSha token slug n
              cmp <- compareFiles token slug base headSha
              case cmp of
                Left e -> pure (unknown ("diff unavailable: " <> T.take 120 e))
                Right c -> do
                  let dhallHit = any (\f -> any (\dpath -> f == dpath || ("/" <> dpath) `T.isSuffixOf` f) (scDhallFiles svc)) (crFiles c)
                  sql <-
                    if null (scSqlSchemas svc)
                      then pure Nothing
                      else do
                        (files, _) <- sqlFromCompare token slug headSha (crPatches c)
                        pure (Just (countStatements (statementsFor (scSqlSchemas svc) files)))
                  pure
                    [ "Env / dhall diff: " <> (if dhallHit || overrideAttached then "Yes" else "No"),
                      case sql of
                        Nothing -> "SQL change: not checked (no schema configured for this service)"
                        Just 0 -> "SQL change: No"
                        Just k -> "SQL change: Yes — " <> T.pack (show k) <> " statement(s) on " <> T.intercalate ", " (scSqlSchemas svc) <> " in this diff; run them before approving"
                    ]
