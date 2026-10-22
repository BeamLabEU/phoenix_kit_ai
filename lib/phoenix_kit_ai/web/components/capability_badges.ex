defmodule PhoenixKitAI.Web.Components.CapabilityBadges do
  @moduledoc """
  The badges for what a model can do (images, tools, JSON schema) as its
  catalogue says: one per capability it has, a muted one with "?" where the
  catalogue does not know, one "unknown" badge when it knows nothing, and
  Anthropic's lifecycle when the model is leaving. Shared by the endpoint
  form's model grid and the task model picker.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAI.Gettext

  alias PhoenixKitAI.Capabilities

  attr(:capabilities, :any, default: nil)

  # What the catalogue says the model can do: a badge per capability it has
  # (a muted one with "?" where it does not know), one "unknown" badge when
  # it knows nothing, and Anthropic's lifecycle when the model is leaving.
  def badges(assigns) do
    ~H"""
    <%= if match?(%Capabilities{}, @capabilities) do %>
      <%= if Enum.all?(Capabilities.declarable(), &(Map.fetch!(@capabilities, &1) == :unknown)) do %>
        <span
          data-capability="unknown"
          class="badge badge-ghost badge-xs h-auto"
          title={gettext("Not reported by the provider")}
        >
          {gettext("Capabilities unknown")}
        </span>
      <% else %>
        <%= for flag <- Capabilities.declarable(), Map.fetch!(@capabilities, flag) != :no do %>
          <% known? = Map.fetch!(@capabilities, flag) == :yes %>
          <span
            data-capability={flag}
            data-state={Map.fetch!(@capabilities, flag)}
            class={[
              "badge badge-xs h-auto",
              if(known?, do: "badge-info badge-outline", else: "badge-ghost")
            ]}
            title={if(!known?, do: gettext("Not reported by the provider"))}
          >
            {label(flag)}{if(!known?, do: "?")}
          </span>
        <% end %>
      <% end %>

      <span
        :if={@capabilities.lifecycle == :deprecated}
        data-lifecycle="deprecated"
        class="badge badge-warning badge-xs h-auto"
      >
        {gettext("Retiring")}
      </span>
      <span
        :if={@capabilities.lifecycle == :retired}
        data-lifecycle="retired"
        class="badge badge-error badge-xs h-auto"
      >
        {gettext("Retired")}
      </span>
    <% end %>
    """
  end

  @doc "The capability in words."
  def label(:vision), do: gettext("Images")
  def label(:tools), do: gettext("Tools")
  def label(:json_schema), do: gettext("JSON schema")
end
