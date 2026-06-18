defmodule BombPartyQuizWeb.InicioLive do
  use BombPartyQuizWeb, :live_view

  alias BombPartyQuiz.{Sala, SalaManager}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:modo, "elegir")
      |> assign(:nombre, "")
      |> assign(:codigo_input, "")
      |> assign(:tematica, "matematica")
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("ir_a_crear", _params, socket) do
    {:noreply, assign(socket, modo: "crear", error: nil)}
  end

  def handle_event("ir_a_unirse", _params, socket) do
    {:noreply, assign(socket, modo: "unirse", error: nil)}
  end

  def handle_event("volver", _params, socket) do
    {:noreply, assign(socket, modo: "elegir", error: nil)}
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
    <div class="min-h-screen bg-neutral-950 flex items-center justify-center p-4">
      <div class="w-full max-w-5xl bg-neutral-900 rounded-3xl overflow-hidden shadow-2xl flex flex-col md:flex-row min-h-[600px]">
        <div class="w-full md:w-[380px] bg-neutral-900 p-8 flex flex-col">
          <div class="flex items-center gap-2 mb-10">
            <span class="text-3xl">💣</span>
            <h1 class="text-2xl font-black text-white tracking-tight">
              Bomb Party <span class="text-orange-400">Quiz</span>
            </h1>
          </div>

          <%= if @error do %>
            <div class="bg-red-950 border border-red-700 text-red-300 text-sm rounded-lg px-4 py-2 mb-4">
              {@error}
            </div>
          <% end %>

          <div class="flex-1 flex flex-col">
            <%= case @modo do %>
              <% "elegir" -> %>
                <div class="space-y-4">
                  <button
                    phx-click="ir_a_crear"
                    class="w-full flex items-center gap-3 py-4 px-5 rounded-2xl bg-sky-900/40 hover:bg-sky-900/60 border border-sky-700/50 text-white font-bold text-lg transition"
                  >
                    <span class="text-2xl">🏠</span>
                    Crear sala
                  </button>
                  <button
                    phx-click="ir_a_unirse"
                    class="w-full flex items-center gap-3 py-4 px-5 rounded-2xl bg-sky-900/40 hover:bg-sky-900/60 border border-sky-700/50 text-white font-bold text-lg transition"
                  >
                    <span class="text-2xl">🔒</span>
                    Unirme con código
                  </button>
                </div>
              <% "crear" -> %>
                <form phx-submit="crear_sala" phx-change="formulario_cambio" class="space-y-4 flex flex-col flex-1">
                  <div>
                    <label class="text-neutral-400 text-sm">Tu nombre</label>
                    <input
                      type="text"
                      value={@nombre}
                      name="nombre"
                      placeholder="Ej. Ana"
                      autocomplete="off"
                      class="w-full mt-1 px-4 py-2 rounded-lg bg-neutral-800 text-white border border-neutral-700 focus:border-orange-400 outline-none"
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
                        Matemática
                      </button>
                      <button
                        type="button"
                        phx-click="elegir_tematica"
                        phx-value-tematica="cultura_general"
                        class={tematica_clase(@tematica, "cultura_general")}
                      >
                        Cultura General
                      </button>
                      <button
                        type="button"
                        phx-click="elegir_tematica"
                        phx-value-tematica="programacion"
                        class={tematica_clase(@tematica, "programacion")}
                      >
                        Lenguajes de Programación
                      </button>
                    </div>
                  </div>

                  <div class="flex-1"></div>

                  <button
                    type="submit"
                    class="w-full py-3 rounded-xl bg-orange-500 hover:bg-orange-400 text-neutral-950 font-bold text-lg transition"
                  >
                    Crear sala
                  </button>
                  <button
                    type="button"
                    phx-click="volver"
                    class="w-full py-2 rounded-xl text-neutral-400 hover:text-white text-sm transition"
                  >
                    Volver
                  </button>
                </form>
              <% "unirse" -> %>
                <form phx-submit="unirse_sala" phx-change="formulario_cambio" class="space-y-4 flex flex-col flex-1">
                  <div>
                    <label class="text-neutral-400 text-sm">Tu nombre</label>
                    <input
                      type="text"
                      value={@nombre}
                      name="nombre"
                      placeholder="Ej. Luis"
                      autocomplete="off"
                      class="w-full mt-1 px-4 py-2 rounded-lg bg-neutral-800 text-white border border-neutral-700 focus:border-orange-400 outline-none"
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
                      class="w-full mt-1 px-4 py-2 rounded-lg bg-neutral-800 text-white border border-neutral-700 focus:border-orange-400 outline-none uppercase tracking-widest text-center text-xl font-mono"
                    />
                  </div>

                  <div class="flex-1"></div>

                  <button
                    type="submit"
                    class="w-full py-3 rounded-xl bg-orange-500 hover:bg-orange-400 text-neutral-950 font-bold text-lg transition"
                  >
                    Unirme
                  </button>
                  <button
                    type="button"
                    phx-click="volver"
                    class="w-full py-2 rounded-xl text-neutral-400 hover:text-white text-sm transition"
                  >
                    Volver
                  </button>
                </form>
            <% end %>
          </div>
        </div>

        <div class="hidden md:block flex-1 relative">
          <img
            src="/images/bombparty_inicio.png"
            alt="Bomb Party Quiz"
            class="w-full h-full object-cover"
          />
        </div>
      </div>
    </div>
    """
  end

  defp tematica_clase(actual, valor) when actual == valor do
    "w-full py-2 rounded-lg bg-orange-500 text-neutral-950 text-left px-4 font-semibold"
  end

  defp tematica_clase(_actual, _valor) do
    "w-full py-2 rounded-lg bg-neutral-800 text-neutral-300 text-left px-4 font-semibold border border-neutral-700 hover:border-neutral-500"
  end
end
