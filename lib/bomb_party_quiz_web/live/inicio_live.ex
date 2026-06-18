defmodule BombPartyQuizWeb.InicioLive do
  use BombPartyQuizWeb, :live_view

  alias BombPartyQuiz.{Sala, SalaManager}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:modo, :elegir)
      |> assign(:nombre, "")
      |> assign(:codigo_input, "")
      |> assign(:tematica, "matematica")
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("ir_a_crear", _params, socket) do
    {:noreply, assign(socket, modo: :crear, error: nil)}
  end

  def handle_event("ir_a_unirse", _params, socket) do
    {:noreply, assign(socket, modo: :unirse, error: nil)}
  end

  def handle_event("volver", _params, socket) do
    {:noreply, assign(socket, modo: :elegir, error: nil)}
  end

  def handle_event("formulario_cambio", params, socket) do
    socket =
      socket
      |> assign(:nombre, Map.get(params, "nombre", socket.assigns.nombre))
      |> assign(:codigo_input, Map.get(params, "codigo", socket.assigns.codigo_input) |> String.upcase())

    {:noreply, socket}
  end

  def handle_event("elegir_tematica", %{"tematica" => tematica}, socket) do
    {:noreply, assign(socket, tematica: tematica)}
  end

  def handle_event("crear_sala", _params, socket) do
    nombre = String.trim(socket.assigns.nombre)

    if nombre == "" do
      {:noreply, assign(socket, error: "Escribe tu nombre para continuar")}
    else
      {:ok, codigo} = SalaManager.crear_sala()
      {:ok, _sala} = Sala.crear(codigo, nombre, socket.assigns.tematica)

      {:noreply,
       socket
       |> push_navigate(to: ~p"/sala/#{codigo}?nombre=#{nombre}&anfitrion=true")}
    end
  end

  def handle_event("unirse_sala", _params, socket) do
    nombre = String.trim(socket.assigns.nombre)
    codigo = String.trim(socket.assigns.codigo_input)

    cond do
      nombre == "" ->
        {:noreply, assign(socket, error: "Escribe tu nombre para continuar")}

      codigo == "" ->
        {:noreply, assign(socket, error: "Escribe el código de la sala")}

      not Sala.existe?(codigo) ->
        {:noreply, assign(socket, error: "No existe ninguna sala con ese código")}

      true ->
        {:noreply, push_navigate(socket, to: ~p"/sala/#{codigo}?nombre=#{nombre}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-b from-black via-neutral-900 to-red-950 flex items-center justify-center px-4">
      <div class="w-full max-w-md">
        <div class="text-center mb-8">
          <h1 class="text-5xl font-black text-white tracking-tight">
            💣 Bomb<span class="text-red-500">Party</span>
          </h1>
          <p class="text-neutral-400 mt-2">Responde antes de que estalle</p>
        </div>

        <div class="bg-neutral-900/80 border border-red-900/50 rounded-2xl p-6 shadow-2xl shadow-red-950/50">
          <%= if @error do %>
            <div class="bg-red-950 border border-red-700 text-red-300 text-sm rounded-lg px-4 py-2 mb-4">
              {@error}
            </div>
          <% end %>

          <%= case @modo do %>
            <% :elegir -> %>
              <div class="space-y-3">
                <button
                  phx-click="ir_a_crear"
                  class="w-full py-3 rounded-xl bg-red-600 hover:bg-red-500 text-white font-bold text-lg transition"
                >
                  Crear sala
                </button>
                <button
                  phx-click="ir_a_unirse"
                  class="w-full py-3 rounded-xl bg-neutral-800 hover:bg-neutral-700 text-white font-bold text-lg transition border border-neutral-700"
                >
                  Unirme con código
                </button>
              </div>
            <% :crear -> %>
              <form phx-submit="crear_sala" phx-change="formulario_cambio" class="space-y-4">
                <div>
                  <label class="text-neutral-400 text-sm">Tu nombre</label>
                  <input
                    type="text"
                    value={@nombre}
                    name="nombre"
                    placeholder="Ej. Ana"
                    autocomplete="off"
                    class="w-full mt-1 px-4 py-2 rounded-lg bg-neutral-800 text-white border border-neutral-700 focus:border-red-500 outline-none"
                  />
                </div>

                <div>
                  <label class="text-neutral-400 text-sm">Temática</label>
                  <div class="grid grid-cols-1 gap-2 mt-1">
                    <button
                      type="button"
                      phx-click="elegir_tematica"
                      phx-value-tematica="matematica"
                      class={tematica_clase(@tematica, "matematica")}
                    >
                      ➕ Matemática
                    </button>
                    <button
                      type="button"
                      phx-click="elegir_tematica"
                      phx-value-tematica="cultura_general"
                      class={tematica_clase(@tematica, "cultura_general")}
                    >
                      🌍 Cultura General
                    </button>
                    <button
                      type="button"
                      phx-click="elegir_tematica"
                      phx-value-tematica="programacion"
                      class={tematica_clase(@tematica, "programacion")}
                    >
                      💻 Lenguajes de Programación
                    </button>
                  </div>
                </div>

                <button
                  type="submit"
                  class="w-full py-3 rounded-xl bg-red-600 hover:bg-red-500 text-white font-bold text-lg transition"
                >
                  Crear sala
                </button>
                <button
                  type="button"
                  phx-click="volver"
                  class="w-full py-2 rounded-xl text-neutral-400 hover:text-white text-sm transition"
                >
                  ← Volver
                </button>
              </form>
            <% :unirse -> %>
              <form phx-submit="unirse_sala" phx-change="formulario_cambio" class="space-y-4">
                <div>
                  <label class="text-neutral-400 text-sm">Tu nombre</label>
                  <input
                    type="text"
                    value={@nombre}
                    name="nombre"
                    placeholder="Ej. Luis"
                    autocomplete="off"
                    class="w-full mt-1 px-4 py-2 rounded-lg bg-neutral-800 text-white border border-neutral-700 focus:border-red-500 outline-none"
                  />
                </div>
                <div>
                  <label class="text-neutral-400 text-sm">Código de sala</label>
                  <input
                    type="text"
                    value={@codigo_input}
                    name="codigo"
                    placeholder="Ej. MJDB"
                    autocomplete="off"
                    class="w-full mt-1 px-4 py-2 rounded-lg bg-neutral-800 text-white border border-neutral-700 focus:border-red-500 outline-none uppercase tracking-widest text-center text-xl font-mono"
                  />
                </div>
                <button
                  type="submit"
                  class="w-full py-3 rounded-xl bg-red-600 hover:bg-red-500 text-white font-bold text-lg transition"
                >
                  Unirme
                </button>
                <button
                  type="button"
                  phx-click="volver"
                  class="w-full py-2 rounded-xl text-neutral-400 hover:text-white text-sm transition"
                >
                  ← Volver
                </button>
              </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp tematica_clase(actual, valor) when actual == valor do
    "w-full py-2 rounded-lg bg-red-600 text-white text-left px-4 font-semibold border border-red-500"
  end

  defp tematica_clase(_actual, _valor) do
    "w-full py-2 rounded-lg bg-neutral-800 text-neutral-300 text-left px-4 font-semibold border border-neutral-700 hover:border-neutral-500"
  end
end
