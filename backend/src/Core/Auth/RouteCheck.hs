{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Compile-time extraction of Servant API routes, plus a runtime check that
-- every declared route has a permission mapping in 'findRoutePermission'.
--
-- Used by 'Core.Server' at startup to turn missing RBAC wiring from a silent
-- security hole into a loud warning (Phase 1) or a hard crash (Phase 2).
--
-- == Supported Servant combinators
--
-- Instances exist for the combinators actually used by @CoreAPI@, plus the
-- ones we expect to add next. If you get an @HasRoutes@ "no instance" error
-- after adding a new combinator to the API, add an instance here.
--
-- [Path builders] @(:\<|\>)@, @(sym :: Symbol) :> api@, @Capture sym a :> api@,
--                 @CaptureAll sym a :> api@.
-- [Passthroughs (do not add segments)] @ReqBody@, @QueryParam@, @QueryParams@,
--                 @QueryFlag@, @Header@, @Description@, @Summary@,
--                 @AuthProtect@, @BasicAuth@, @Vault@, @RemoteHost@,
--                 @IsSecure@, @HttpVersion@, @WithNamedContext@.
-- [Leaves] @Verb method status cts a@ (GET, POST, PUT, etc.), @Raw@,
--          @EmptyAPI@, @NoContentVerb@.
--
-- Not yet supported (will fail to compile if added to the API): @UVerb@,
-- @StreamGet@, @StreamPost@, @NamedRoutes@. Add instances when needed.
module Core.Auth.RouteCheck
  ( HasRoutes (..),
    RouteEntry,
    findUnmappedRoutes,
    formatRoute,
  )
where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Servant.API

-- | A single API route as @(method, path-segments)@. Capture segments are
-- rendered as @":name"@ to match the wildcard convention used by
-- 'Core.Auth.Middleware.findRoutePermission'.
type RouteEntry = (Text, [Text])

-- | Walk a Servant API type at compile time and collect all leaf routes.
class HasRoutes api where
  listRoutes :: Proxy api -> [RouteEntry]

-- Combinators

instance (HasRoutes a, HasRoutes b) => HasRoutes (a :<|> b) where
  listRoutes _ = listRoutes (Proxy :: Proxy a) <> listRoutes (Proxy :: Proxy b)

instance (KnownSymbol sym, HasRoutes api) => HasRoutes ((sym :: Symbol) :> api) where
  listRoutes _ =
    let seg = T.pack (symbolVal (Proxy :: Proxy sym))
     in map (prependSeg seg) (listRoutes (Proxy :: Proxy api))

instance (KnownSymbol sym, HasRoutes api) => HasRoutes (Capture sym a :> api) where
  listRoutes _ =
    let seg = ":" <> T.pack (symbolVal (Proxy :: Proxy sym))
     in map (prependSeg seg) (listRoutes (Proxy :: Proxy api))

instance (KnownSymbol sym, HasRoutes api) => HasRoutes (CaptureAll sym a :> api) where
  listRoutes _ =
    let seg = ":" <> T.pack (symbolVal (Proxy :: Proxy sym)) <> "*"
     in map (prependSeg seg) (listRoutes (Proxy :: Proxy api))

-- Passthrough combinators (don't add path segments)

instance HasRoutes api => HasRoutes (ReqBody cts a :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (QueryParam sym a :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (QueryParams sym a :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (QueryFlag sym :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (Header sym a :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (Description sym :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (Summary sym :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

-- Auth and context combinators — pass through without adding segments.

instance HasRoutes api => HasRoutes (AuthProtect tag :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (BasicAuth realm usr :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (Vault :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (RemoteHost :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (IsSecure :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (HttpVersion :> api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

instance HasRoutes api => HasRoutes (WithNamedContext name subs api) where
  listRoutes _ = listRoutes (Proxy :: Proxy api)

-- Verb leaves — one entry per HTTP method.
-- Servant's 'reflectMethod' returns a 'ByteString'; decode as UTF-8.

instance ReflectMethod method => HasRoutes (Verb method status cts a) where
  listRoutes _ = [(TE.decodeUtf8 (reflectMethod (Proxy :: Proxy method)), [])]

-- 'NoContentVerb' is the 204-returning variant of 'Verb'.
instance ReflectMethod method => HasRoutes (NoContentVerb method) where
  listRoutes _ = [(TE.decodeUtf8 (reflectMethod (Proxy :: Proxy method)), [])]

-- 'Raw' serves an arbitrary WAI 'Application' and does not commit to a
-- method or add segments. We emit a single @("*", [])@ entry so a bare
-- 'Raw' leaf appears in the route list; wrapped in path segments (e.g.
-- @"static" :> Raw@) the entry becomes @("*", ["static"])@. 'findRoutePermission'
-- treats @"*"@ as an unknown method and the route will be reported unmapped —
-- which is the correct default, since Raw cannot express RBAC intent.
instance HasRoutes Raw where
  listRoutes _ = [("*", [])]

-- 'EmptyAPI' contributes no routes.
instance HasRoutes EmptyAPI where
  listRoutes _ = []

prependSeg :: Text -> RouteEntry -> RouteEntry
prependSeg s (m, ps) = (m, s : ps)

-- | Given the full set of API routes, return those that do NOT have a
-- permission mapping — callers can then log or crash.
--
-- The predicate is supplied by the caller so we don't create a cyclic import
-- with @Core.Auth.Middleware@.
findUnmappedRoutes ::
  -- | @isMapped method pathSegs@ — returns True if the route has a permission
  (Text -> [Text] -> Bool) ->
  [RouteEntry] ->
  [RouteEntry]
findUnmappedRoutes isMapped = filter (\(m, ps) -> not (isMapped m ps))

-- | Human-readable route formatter: @"GET /releases/:id/approve"@.
formatRoute :: RouteEntry -> Text
formatRoute (m, ps) = m <> " /" <> T.intercalate "/" ps
