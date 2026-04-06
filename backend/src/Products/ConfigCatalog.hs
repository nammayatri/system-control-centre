{-# LANGUAGE OverloadedStrings #-}

{- | The product-aware config catalog.

This is the single place in the codebase that knows about every
product's config list. It sits in the @Products/@ layer (NOT
@Shared/@) so that 'Shared.Config.Registry' can stay product-agnostic.

To add configs for a new product: import its @<product>Configs@ list
here and concat it into 'allConfigEntries'. This is the ONLY edit
needed — downstream consumers look up via 'findConfigEntry' which
delegates to 'Shared.Config.Registry.findConfigEntryIn'.

Layer note: this module is allowed to import from @Products.*@ and
@Shared.*@ (products-aware layer may depend on both). It exists because
the pre-existing @Shared.Config.Registry@ violated the layer rule
"Shared must not import Products" — see CONTEXT.md, Product Boundary
task #24 V3.
-}
module Products.ConfigCatalog (
    allConfigEntries,
    findConfigEntry,
)
where

import Data.Text (Text)
import Products.Autopilot.Config (autopilotConfigs)
import Shared.Config.Registry (findConfigEntryIn, globalConfigs)
import Shared.Config.Types (ConfigEntry)

{- | Every config entry the server knows about: global flags first, then
every product's own list. If you add a new product, append its
@<product>Configs@ here.
-}
allConfigEntries :: [ConfigEntry]
allConfigEntries = globalConfigs ++ autopilotConfigs

{- | Look up a config entry by key in the full product-aware catalog.
Thin wrapper over 'Shared.Config.Registry.findConfigEntryIn' that
pre-binds the catalog list.
-}
findConfigEntry :: Text -> Maybe ConfigEntry
findConfigEntry = findConfigEntryIn allConfigEntries
