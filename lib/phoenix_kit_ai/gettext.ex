defmodule PhoenixKitAI.Gettext do
  @moduledoc """
  Gettext backend for `phoenix_kit_ai`.

  Owns the translation catalogues under `priv/gettext/`. Locale is set
  per-request by the parent application; this module is only responsible
  for looking msgids up against the active locale.

  See [`guides/per-module-i18n.md`](https://github.com/BeamLabEU/phoenix_kit/blob/main/guides/per-module-i18n.md)
  in `phoenix_kit` core for the full setup and conventions — a relative
  `guides/` path doesn't resolve for a Hex consumer, since that directory
  isn't shipped in core's package `files:`.
  """
  # One compiled module per locale and domain: the catalogues are large, and
  # split modules compile in parallel instead of one long serial compile that
  # blocks every app depending on this package. Lookups are unchanged.
  use Gettext.Backend,
    otp_app: :phoenix_kit_ai,
    split_module_by: [:locale, :domain]
end
