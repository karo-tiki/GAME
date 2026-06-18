defmodule BombPartyQuizWeb.JuegoLive do
  use BombPartyQuizWeb, :live_view

  alias BombPartyQuiz.Sala
  alias Phoenix.PubSub

  @pubsub BombPartyQuiz.PubSub

  @impl true
  def mount(%{"codigo" => codigo}, _session, socket) do
    {:ok, socket |> assign(:codigo, codigo) |> assign(:cargado, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    codigo = socket.assigns.codigo
    nombre = Map.get(params, "nombre", "")

    if socket.assigns[:cargado] do
      {:noreply, socket}
    else
      if not Sala.existe?(codigo) do
        {:noreply, push_navigate(socket, to: ~p"/")}
      else
        sala = Sala.estado(codigo)

        if connected?(socket) do
          PubSub.subscribe(@pubsub, Sala.topic(codigo))
          :timer.send_interval(1000, self(), :tick)
        end

        {:noreply,
         socket
         |> assign(:cargado, true)
         |> assign(:nombre, nombre)
         |> assign(:sala, sala)
         |> assign(:tiempo_restante, sala.tiempo_restante)
         |> assign(:respuesta, "")
         |> assign(:flash_resultado, nil)}
      end
    end
  end

  @impl true
  def handle_event("actualizar_respuesta", %{"respuesta" => valor}, socket) do
    {:noreply, assign(socket, :respuesta, valor)}
  end

  def handle_event("elegir_opcion", %{"opcion" => opcion}, socket) do
    enviar_respuesta(socket, opcion)
  end

  def handle_event("enviar_respuesta", _params, socket) do
    enviar_respuesta(socket, socket.assigns.respuesta)
  end

  defp enviar_respuesta(socket, respuesta) do
    Sala.responder(socket.assigns.codigo, socket.assigns.nombre, respuesta)
    {:noreply, assign(socket, :respuesta, "")}
  end

  @impl true
  def handle_info(:tick, socket) do
    nuevo_tiempo = max(socket.assigns.tiempo_restante - 1, 0)
    {:noreply, assign(socket, :tiempo_restante, nuevo_tiempo)}
  end

  def handle_info({:nuevo_turno, sala}, socket) do
    {:noreply,
     socket
     |> assign(:sala, sala)
     |> assign(:tiempo_restante, sala.tiempo_restante)
     |> assign(:respuesta, "")
     |> assign(:flash_resultado, nil)}
  end

  def handle_info({:respuesta_correcta, jugador}, socket) do
    {:noreply, assign(socket, :flash_resultado, {:correcta, jugador})}
  end

  def handle_info({:respuesta_incorrecta, jugador, sala}, socket) do
    {:noreply,
     socket
     |> assign(:sala, sala)
     |> assign(:flash_resultado, {:incorrecta, jugador})}
  end

  def handle_info({:jugadores_actualizados, sala}, socket) do
    {:noreply, assign(socket, :sala, sala)}
  end

  def handle_info({:partida_finalizada, sala}, socket) do
    {:noreply, assign(socket, :sala, sala)}
  end

  def handle_info(_otro, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-b from-black via-neutral-900 to-red-950 px-4 py-6">
      <div class="max-w-2xl mx-auto">
        <%= if @sala.estado == :finalizado do %>
          {render_fin(assigns)}
        <% else %>
          {render_juego(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp render_fin(assigns) do
    ~H"""
    <div class="text-center py-20">
      <p class="text-6xl mb-4">*</p>
      <%= if @sala.ganador do %>
        <h1 class="text-4xl font-black text-white">
          Ganador: <span class="text-yellow-400">{@sala.ganador}</span>
        </h1>
      <% else %>
        <h1 class="text-3xl font-black text-white">La partida termino sin ganador</h1>
      <% end %>
      <a href="/" class="inline-block mt-8 px-6 py-3 rounded-xl bg-red-600 hover:bg-red-500 text-white font-bold transition">
        Volver al inicio
      </a>
    </div>
    """
  end

  defp render_juego(assigns) do
    ~H"""
    <div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <div
          :for={jugador <- @sala.jugadores}
          class={[
            "rounded-xl p-3 text-center border transition",
            jugador.nombre == @sala.jugador_con_bomba && "border-red-500 bg-red-950/60 scale-105",
            jugador.nombre != @sala.jugador_con_bomba && "border-neutral-800 bg-neutral-900/60",
            jugador.vidas == 0 && "opacity-40"
          ]}
        >
          <p class="text-white font-semibold text-sm truncate">
            {jugador.nombre}
            <span :if={jugador.nombre == @sala.jugador_con_bomba}>(bomba)</span>
          </p>
          <p class="text-lg mt-1">
            <%= for n <- 1..3 do %>
              <%= if n <= jugador.vidas do %>
                [v]
              <% else %>
                [x]
              <% end %>
            <% end %>
          </p>
          <p :if={jugador.vidas == 0} class="text-xs text-neutral-500 mt-1">espectador</p>
        </div>
      </div>

      <div :if={@flash_resultado} class="text-center mb-4">
        <%= case @flash_resultado do %>
          <% {:correcta, jugador} -> %>
            <p class="text-green-400 font-bold">{jugador} respondio correctamente</p>
          <% {:incorrecta, jugador} -> %>
            <p class="text-red-400 font-bold">{jugador} fallo y perdio una vida</p>
        <% end %>
      </div>

      <div class="bg-neutral-900/80 border border-red-900/50 rounded-2xl p-6 shadow-2xl shadow-red-950/50">
        <%= if @sala.pregunta_actual do %>
          <div class="text-center mb-4">
            <p class="text-neutral-400 text-sm">Le toca a</p>
            <p class="text-2xl font-black text-white">{@sala.jugador_con_bomba}</p>
          </div>

          <div class="mb-6">
            <p class={[
              "text-center text-4xl font-black mb-2",
              @tiempo_restante <= 2 && "text-red-500 animate-pulse",
              @tiempo_restante > 2 && "text-white"
            ]}>
              {@tiempo_restante}s
            </p>
            <div class="w-full h-3 bg-neutral-800 rounded-full overflow-hidden">
              <div
                class={[
                  "h-full transition-all duration-1000 ease-linear",
                  @tiempo_restante <= 2 && "bg-red-500",
                  @tiempo_restante > 2 && "bg-orange-500"
                ]}
                style={"width: #{porcentaje_tiempo(@tiempo_restante, @sala.pregunta_actual)}%"}
              >
              </div>
            </div>
          </div>

          <p class="text-xl text-white text-center font-semibold mb-6">
            {@sala.pregunta_actual["pregunta"]}
          </p>

          <%= if @nombre == @sala.jugador_con_bomba do %>
            <%= if @sala.pregunta_actual["tipo"] == "seleccion" do %>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <button
                  :for={opcion <- @sala.pregunta_actual["opciones"]}
                  phx-click="elegir_opcion"
                  phx-value-opcion={opcion}
                  class="py-3 px-4 rounded-xl bg-neutral-800 hover:bg-red-700 text-white font-semibold transition border border-neutral-700"
                >
                  {opcion}
                </button>
              </div>
            <% else %>
              <form phx-submit="enviar_respuesta" phx-change="actualizar_respuesta" class="flex gap-2">
                <input
                  type="text"
                  name="respuesta"
                  value={@respuesta}
                  autocomplete="off"
                  autofocus
                  placeholder="Escribe tu respuesta..."
                  class="flex-1 px-4 py-3 rounded-xl bg-neutral-800 text-white border border-neutral-700 focus:border-red-500 outline-none"
                />
                <button type="submit" class="px-6 py-3 rounded-xl bg-red-600 hover:bg-red-500 text-white font-bold transition">
                  Enviar
                </button>
              </form>
            <% end %>
          <% else %>
            <p class="text-center text-neutral-500 text-sm">
              {@sala.jugador_con_bomba} esta respondiendo...
            </p>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp porcentaje_tiempo(restante, pregunta) do
    total = BombPartyQuiz.Preguntas.tiempo_segundos(pregunta)
    max(restante / total * 100, 0)
  end
end

