{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}

{- | The 'KnownPermission' typeclass, factored out into its own module so
that product modules can provide instances WITHOUT dragging in any of
the auth query code that "Core.Auth.Protected" depends on.

The dependency shape is:

> Core.Auth.Permission     (this module, no deps)
>     ^
>     |  provides  KnownPermission
>     |
> Products.*.Permission    (defines AutopilotPermission data kind + instances)
>     ^
>     |  imported by
>     |
> Products.Types           (the union of all product permissions — used by RBAC queries)
>     ^
>     |  imported by
>     |
> Core.Auth.Queries        (runs SQL against sc_person_product_access)
>     ^
>     |  imported by
>     |
> Core.Auth.Protected      (the Servant combinator — calls Queries + re-exports KnownPermission)

If 'KnownPermission' lived in 'Core.Auth.Protected' instead, the chain
@Products.Types → Products.*.Permission → Core.Auth.Protected →
 Core.Auth.Queries → Products.Types@ would form a module import cycle.
Keeping the class in a leaf module breaks that cycle.
-}
module Core.Auth.Permission (
    KnownPermission (..),
)
where

import Data.Proxy (Proxy)
import Data.Text (Text)

{- | Bridge from a type-level permission tag to its runtime @(product, action)@
pair. Products promote their permission ADT to a data kind (via 'DataKinds')
and provide one instance per constructor.
-}
class KnownPermission (perm :: k) where
    permissionProduct :: Proxy perm -> Text
    permissionName :: Proxy perm -> Text
