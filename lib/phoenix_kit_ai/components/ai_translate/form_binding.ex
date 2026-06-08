defmodule PhoenixKitAI.Components.AITranslate.FormBinding do
  @moduledoc """
  The small storage-specific contract a form LiveView supplies to the
  shared AI-translate glue (`PhoenixKitAI.Components.AITranslate.FormGlue`).

  Everything about the modal/progress/stall state machine, the dispatch, and
  the PubSub event handling is generic and lives in the glue. The only things
  that differ per consumer are *where/how translations are stored in the live
  changeset* and *who the actor is* — those three callbacks.

  Implementations are tiny modules (see `PhoenixKitCatalogue.AITranslateBinding`
  / `PhoenixKitProjects.AITranslateBinding`). The module is passed once to
  `FormGlue.assign_ai_translation/4` and stashed in assigns.
  """

  @doc """
  The enabled non-primary language codes that ALREADY have at least one
  non-blank translatable field, read from the live form's assigns (so it
  reflects unsaved + just-translated state). The glue subtracts these from the
  enabled set to get the "missing" list.
  """
  @callback existing_translation_langs(resource_type :: String.t(), assigns :: map()) ::
              [String.t()]

  @doc """
  Merge a completed translation's `fields` (plain engine field names →
  translated values) into `changeset` for `lang`, returning the updated
  changeset. PURE changeset→changeset — the glue re-assigns it via the LV's
  own assign helper, so this must not touch the socket.
  """
  @callback apply_translation(
              resource_type :: String.t(),
              changeset :: Ecto.Changeset.t(),
              lang :: String.t(),
              fields :: map()
            ) :: Ecto.Changeset.t()

  @doc "The acting user's UUID (or nil) for the translation audit trail."
  @callback actor_uuid(socket :: Phoenix.LiveView.Socket.t()) :: Ecto.UUID.t() | nil
end
