defmodule PhoenixKitAI.Web.Components.CapabilityBadges do
  @moduledoc """
  The badges for what a model can do (images, documents, image generation,
  tools, JSON schema) as its catalogue says: one per capability it has, a
  grey one with "?" where nobody verified it (never styled like a missing
  one, which has no badge), one "unknown" badge when nothing is known, and
  Anthropic's lifecycle when the model is leaving. Shared by the endpoint
  form's model grid and the task model picker. Each badge's `title` is the
  capability explained (`explain/1`, the one source of those texts, also
  read by `glossary/1` and `how_to_determine/1`).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAI.Gettext

  alias PhoenixKitAI.Capabilities

  attr(:capabilities, :any, default: nil)

  attr(:context, :atom,
    default: :endpoint,
    values: [:endpoint, :catalogue],
    doc:
      "`:catalogue` for a model no endpoint has yet (recommendations): the hint on a \"?\" then only says it is not verified"
  )

  # What the catalogue says the model can do: a badge per capability it has
  # (a grey one with "?" where nobody verified it), one "unknown" badge when
  # nothing is known, and Anthropic's lifecycle when the model is leaving.
  def badges(assigns) do
    ~H"""
    <%= if match?(%Capabilities{}, @capabilities) do %>
      <%= if Enum.all?(Capabilities.declarable(), &(Map.fetch!(@capabilities, &1) == :unknown)) do %>
        <span
          data-capability="unknown"
          class="badge badge-ghost badge-xs h-auto"
          title={hint(@context)}
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
            title={badge_title(flag, known?, @context)}
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
  def label(:file_input), do: gettext("Documents")
  def label(:image_output), do: gettext("Image generation")
  def label(:tools), do: gettext("Tools")
  def label(:json_schema), do: gettext("JSON schema")
  def label(:json), do: gettext("JSON")
  def label(:context), do: gettext("Context")

  # The capabilities explained, in the glossary's order.
  @explained [:vision, :file_input, :image_output, :tools, :json_schema, :json, :context]

  @doc "The capabilities `explain/1` knows, in the glossary's order."
  def explained, do: @explained

  @doc """
  A capability in plain words: what it is, which task needs it and how to
  tell whether a model has it. The one source of these texts — the badges'
  titles, the glossary and the endpoint form's declaration all read it.
  """
  @spec explain(atom()) :: %{what: String.t(), needed_by: String.t(), check: String.t()}
  def explain(:vision),
    do: %{
      what:
        gettext(
          "Images: the model can look at pictures sent with the request — photos, scans, screenshots."
        ),
      needed_by:
        gettext("Needed by tasks that read a photo, for example recognising the items in it."),
      check:
        gettext(
          "How to tell: the model card at the operator or on OpenRouter lists image input; or send a test request with a picture."
        )
    }

  def explain(:file_input),
    do: %{
      what: gettext("Documents: the model can read files such as PDFs sent with the request."),
      needed_by: gettext("Needed by tasks that read an uploaded document."),
      check:
        gettext(
          "How to tell: the model card at the operator or on OpenRouter lists file or PDF input; or send a test request with a document."
        )
    }

  def explain(:image_output),
    do: %{
      what: gettext("Image generation: the model answers with a picture, not only with text."),
      needed_by: gettext("Needed by tasks that draw or edit images."),
      check:
        gettext(
          "How to tell: the model card at the operator or on OpenRouter lists image output; or send a test request that asks for a picture."
        )
    }

  def explain(:tools),
    do: %{
      what: gettext("Tools: the model can ask the site to run an action or look up data."),
      needed_by: gettext("Needed by an assistant that acts on the site."),
      check:
        gettext(
          "How to tell: the model card at the operator or on OpenRouter lists tools (function calling); or send a test request with a tool."
        )
    }

  def explain(:json_schema),
    do: %{
      what:
        gettext(
          "JSON schema: the model answers with a strictly filled-in form that the site reads without errors."
        ),
      needed_by: gettext("Needed by tasks that parse the answer (for example picking items)."),
      check:
        gettext(
          "How to tell: the model card at the operator or on OpenRouter lists structured outputs (JSON schema); or send a test request with a schema."
        )
    }

  def explain(:json),
    do: %{
      what:
        gettext(
          "JSON: the model answers in JSON, without a promise that every field of a form is there."
        ),
      needed_by:
        gettext(
          "Needed by tasks that read a structured answer and can live with a missing field."
        ),
      check:
        gettext(
          "How to tell: the model card at the operator or on OpenRouter lists JSON mode (response format); or send a test request that asks for JSON."
        )
    }

  def explain(:context),
    do: %{
      what:
        gettext(
          "Context: how much text, in tokens, the model takes in one request — the question, the data sent with it and the answer together."
        ),
      needed_by:
        gettext(
          "Needed by tasks with long inputs, such as large documents or many items at once."
        ),
      check:
        gettext(
          "How to tell: the model card at the operator lists the context window; OpenRouter shows it for every model."
        )
    }

  @doc "`explain/1` as one line, for a `title`."
  @spec explain_text(atom()) :: String.t()
  def explain_text(flag) do
    %{what: what, needed_by: needed_by, check: check} = explain(flag)
    Enum.join([what, needed_by, check], " ")
  end

  @doc "A capability's value in words: yes, no or «?»."
  def value_label(:yes), do: gettext("Yes")
  def value_label(:no), do: gettext("No")
  def value_label(_unknown), do: "?"

  @doc """
  Where a capability's value comes from: the provider's catalogue, a
  declaration on the endpoint, or a test call (no such source yet).
  """
  def source_label(:catalogue), do: gettext("from the catalogue")
  def source_label(:manual), do: gettext("marked by hand")
  def source_label(:call), do: gettext("checked by a call")

  attr(:id, :string, required: true)
  attr(:flags, :list, default: @explained)
  attr(:class, :any, default: nil)

  @doc """
  A collapsed glossary of the capabilities: each one's `explain/1` in three
  lines. Keyboard-reachable (a `<details>`), unlike a `title`.
  """
  def glossary(assigns) do
    ~H"""
    <details
      id={@id}
      class={["collapse collapse-arrow min-w-0 border border-base-300", @class]}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <summary class="collapse-title text-sm font-medium">
        {gettext("What the capabilities mean")}
      </summary>
      <dl class="collapse-content flex flex-col gap-3 text-sm">
        <div :for={flag <- @flags} data-explain={flag}>
          <% explanation = explain(flag) %>
          <dt class="font-medium">{label(flag)}</dt>
          <dd class="text-base-content/80">{explanation.what}</dd>
          <dd class="text-base-content/70">{explanation.needed_by}</dd>
          <dd class="text-base-content/60">{explanation.check}</dd>
        </div>
      </dl>
    </details>
    """
  end

  @openai_models "https://developers.openai.com/api/docs/models"
  @xai_models "https://docs.x.ai/developers/models"
  @zai_overview "https://docs.z.ai/guides/overview/overview"
  @zai_vision_example "https://docs.z.ai/guides/vlm/glm-4.5v"
  @openrouter_models "https://openrouter.ai/models"

  attr(:id, :string, required: true)

  @doc """
  How to determine a model's capabilities when its operator has no
  capability catalogue (Z.ai, OpenAI, xAI, another OpenAI-compatible one):
  where to look, what a model's name usually hints at, and the rule to leave
  «?» when unsure.
  """
  def how_to_determine(assigns) do
    assigns =
      assign(assigns,
        links: [
          {"OpenAI", gettext("the model list"), @openai_models},
          {"xAI", gettext("the model list"), @xai_models},
          {"Z.ai", gettext("the model overview"), @zai_overview},
          {"Z.ai", gettext("an example of a model that reads images"), @zai_vision_example}
        ],
        openrouter_models: @openrouter_models
      )

    ~H"""
    <details
      id={@id}
      class="collapse collapse-arrow min-w-0 border border-base-300"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <summary class="collapse-title text-sm font-medium">
        {gettext("How to determine a model's capabilities")}
      </summary>
      <div class="collapse-content flex flex-col gap-3 text-sm">
        <p>
          {gettext(
            "Operators without a capability catalogue (Z.ai, OpenAI, xAI and other OpenAI-compatible ones) do not say what a model can do, so it is marked here."
          )}
        </p>

        <div>
          <div class="font-medium">{gettext("Where to look")}</div>
          <ul class="list-disc pl-5">
            <li :for={{operator, what, url} <- @links}>
              {operator} — {what}:
              <a href={url} target="_blank" rel="noopener noreferrer" class="link link-primary break-all">
                {url}
              </a>
            </li>
            <li>
              {gettext(
                "Another OpenAI-compatible operator — its own model page; OpenRouter lists the models of many operators with their capabilities:"
              )}
              <a
                href={@openrouter_models}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-primary break-all"
              >
                {@openrouter_models}
              </a>
            </li>
          </ul>
        </div>

        <div>
          <div class="font-medium">{gettext("Hints in the name (usually, not always)")}</div>
          <ul class="list-disc pl-5">
            <li>{gettext("A GLM model with a “v” in its name (glm-4.5v) usually reads images.")}</li>
            <li>
              {gettext("“image” or “imagine” in a name usually means the model generates images.")}
            </li>
          </ul>
        </div>

        <p class="font-medium">
          {gettext(
            "Not sure — leave it at «?», not «yes»: a «yes» switches off the protection against an unsuitable model."
          )}
        </p>
        <p>{gettext("You can check by sending a test request in the Playground.")}</p>
      </div>
    </details>
    """
  end

  @doc "The hint on a capability nobody verified: where to mark it."
  def unverified_hint, do: gettext("Not verified — mark it on the endpoint")

  @doc "The hint on a capability nobody verified, for a model no endpoint has yet."
  def catalogue_hint, do: gettext("Not verified")

  defp hint(:catalogue), do: catalogue_hint()
  defp hint(_context), do: unverified_hint()

  # The explanation, and for a capability nobody verified the hint after it.
  defp badge_title(flag, true, _context), do: explain_text(flag)
  defp badge_title(flag, false, context), do: explain_text(flag) <> " " <> hint(context)
end
