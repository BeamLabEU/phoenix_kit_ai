defmodule PhoenixKitAI.ReviewHandler do
  @moduledoc """
  What an app does when a review of its kind is decided
  (`PhoenixKitAI.Reviews`). Registered per kind:

      config :phoenix_kit_ai, review_handlers: %{
        "listing_description" => MyApp.ListingDescriptionReview
      }

  `on_decide/1` gets the decided review (`status` `"confirmed"` or
  `"rejected"`, the final `payload`) inside the decision's transaction:
  `:ok` / `{:ok, _}` commits the decision with what the handler wrote,
  `{:error, reason}` or a raise rolls both back and the review stays pending.

  `summary/1` (optional) is the one line the admin list shows for a review
  of the kind instead of its payload — the app knows what matters in it.
  """

  @callback on_decide(PhoenixKitAI.Review.t()) :: :ok | {:ok, term()} | {:error, term()}
  @callback summary(PhoenixKitAI.Review.t()) :: String.t()

  @optional_callbacks summary: 1
end
