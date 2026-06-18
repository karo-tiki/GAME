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
          :timer.send_interval(1000, self(), "tick")
        end

        {:noreply,
         socket
         |> assign(:cargado, true)
         |> assign(:nombre, nombre)
         |> assign(:sala, sala)
         |> assign(:tiempo_restante, sala.tiempo_restante)
         |> assign(:respuesta, "")
         |> assign(:flash_resultado, nil)
         |> assign(:evento_anuncio, nil)
         |> assign(:poder_seleccionado, nil)}
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

  def handle_event("click_poder", %{"poder" => poder}, socket) do
    if poder in ["robar_puntos", "bomba_dirigida"] do
      {:noreply, assign(socket, :poder_seleccionado, poder)}
    else
      Sala.usar_poder(socket.assigns.codigo, socket.assigns.nombre, poder)
      {:noreply, socket}
    end
  end

  def handle_event("elegir_objetivo", %{"objetivo" => objetivo}, socket) do
    poder = socket.assigns.poder_seleccionado
    Sala.usar_poder(socket.assigns.codigo, socket.assigns.nombre, poder, objetivo)
    {:noreply, assign(socket, :poder_seleccionado, nil)}
  end

  def handle_event("cancelar_seleccion_poder", _params, socket) do
    {:noreply, assign(socket, :poder_seleccionado, nil)}
  end

  defp enviar_respuesta(socket, respuesta) do
    Sala.responder(socket.assigns.codigo, socket.assigns.nombre, respuesta)
    {:noreply, assign(socket, :respuesta, "")}
  end

  @impl true
  def handle_info("tick", socket) do
    nuevo_tiempo = max(socket.assigns.tiempo_restante - 1, 0)
    {:noreply, assign(socket, :tiempo_restante, nuevo_tiempo)}
  end

  def handle_info({"nuevo_turno", sala}, socket) do
    {:noreply,
     socket
     |> assign(:sala, sala)
     |> assign(:tiempo_restante, sala.tiempo_restante)
     |> assign(:respuesta, "")
     |> assign(:flash_resultado, nil)
     |> assign(:poder_seleccionado, nil)}
  end

  def handle_info({"respuesta_correcta", jugador}, socket) do
    {:noreply, assign(socket, :flash_resultado, {"correcta", jugador})}
  end

  def handle_info({"respuesta_incorrecta", jugador, sala}, socket) do
    {:noreply,
     socket
     |> assign(:sala, sala)
     |> assign(:flash_resultado, {"incorrecta", jugador})}
  end

  def handle_info({"jugadores_actualizados", sala}, socket) do
    {:noreply, assign(socket, :sala, sala)}
  end

  def handle_info({"partida_finalizada", sala}, socket) do
    {:noreply, assign(socket, :sala, sala)}
  end

  def handle_info({"poder_ganado", jugador, poder}, socket) do
    mensaje = "#{jugador} gano el poder: #{nombre_poder(poder)}"
    {:noreply, assign(socket, :flash_resultado, {"poder_ganado", mensaje})}
  end

  def handle_info({"poder_usado", jugador, poder}, socket) do
    mensaje = "#{jugador} uso: #{nombre_poder(poder)}"
    {:noreply, assign(socket, :flash_resultado, {"poder_usado", mensaje})}
  end

  # El timer del servidor se reprogramo con +5s; sincronizamos el contador
  # visual al instante para que la barra y el numero salten de inmediato.
  def handle_info({"tiempo_extendido", jugador, sala}, socket) do
    mensaje = "#{jugador} congelo el tiempo: +5 segundos"

    {:noreply,
     socket
     |> assign(:sala, sala)
     |> assign(:tiempo_restante, sala.tiempo_restante)
     |> assign(:flash_resultado, {"poder_usado", mensaje})}
  end

  def handle_info({"evento_activado", evento}, socket) do
    {:noreply, assign(socket, :evento_anuncio, evento)}
  end

  def handle_info(_otro, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-b from-black via-neutral-900 to-red-950 px-4 py-6">
      <div class="max-w-2xl mx-auto">
        <%= if @sala.estado == "finalizado" do %>
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
      <div class="mt-8 max-w-sm mx-auto bg-neutral-900/80 border border-neutral-800 rounded-xl p-4">
        <p class="text-neutral-400 text-sm mb-2">Marcador final</p>
        <div :for={j <- Enum.sort_by(@sala.jugadores, & -&1.puntos)} class="flex justify-between text-white py-1">
          <span>{j.nombre}</span>
          <span class="font-bold">{j.puntos} pts</span>
        </div>
      </div>
      <a href="/" class="inline-block mt-8 px-6 py-3 rounded-xl bg-red-600 hover:bg-red-500 text-white font-bold transition">
        Volver al inicio
      </a>
    </div>
    """
  end

  defp render_juego(assigns) do
    ~H"""
    <div>
      <div :if={@evento_anuncio} class="text-center mb-4 bg-purple-900/60 border border-purple-500 rounded-xl py-2 px-4">
        <p class="text-purple-200 font-bold text-sm">{texto_evento(@evento_anuncio)}</p>
      </div>

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
          <p class="text-yellow-400 text-xs font-bold mt-1">{jugador.puntos} pts</p>
          <p :if={jugador.racha > 0} class="text-orange-400 text-xs mt-1">racha x{jugador.racha}</p>
          <p :if={jugador.escudo_activo} class="text-cyan-300 text-xs mt-1">escudo activo</p>

          <div :if={jugador.poderes != []} class="flex justify-center gap-1 mt-2 flex-wrap">
            <button
              :for={poder <- jugador.poderes}
              type="button"
              disabled={jugador.nombre != @nombre or jugador.nombre != @sala.jugador_con_bomba}
              phx-click="click_poder"
              phx-value-poder={poder}
              class={[
                "text-xs px-2 py-1 rounded-lg border",
                jugador.nombre == @nombre and jugador.nombre == @sala.jugador_con_bomba &&
                  "bg-purple-700 border-purple-400 text-white cursor-pointer hover:bg-purple-600",
                not (jugador.nombre == @nombre and jugador.nombre == @sala.jugador_con_bomba) &&
                  "bg-neutral-800 border-neutral-700 text-neutral-400 cursor-not-allowed"
              ]}
              title={nombre_poder(poder)}
            >
              {icono_poder(poder)}
            </button>
          </div>
          <p :if={jugador.vidas == 0} class="text-xs text-neutral-500 mt-1">espectador</p>
        </div>
      </div>

      <div :if={@flash_resultado} class="text-center mb-4">
        <%= case @flash_resultado do %>
          <% {"correcta", jugador} -> %>
            <p class="text-green-400 font-bold">{jugador} respondio correctamente</p>
          <% {"incorrecta", jugador} -> %>
            <p class="text-red-400 font-bold">{jugador} fallo y perdio una vida</p>
          <% {"poder_ganado", mensaje} -> %>
            <p class="text-purple-300 font-bold">{mensaje}</p>
          <% {"poder_usado", mensaje} -> %>
            <p class="text-cyan-300 font-bold">{mensaje}</p>
        <% end %>
      </div>

      <div :if={@poder_seleccionado} class="bg-purple-950/80 border border-purple-500 rounded-2xl p-4 mb-4">
        <p class="text-purple-200 text-sm text-center mb-3">
          {texto_seleccion(@poder_seleccionado)}
        </p>
        <div class="grid grid-cols-2 gap-2">
          <button
            :for={j <- otros_jugadores_activos(@sala, @nombre)}
            phx-click="elegir_objetivo"
            phx-value-objetivo={j.nombre}
            class="py-2 px-3 rounded-lg bg-purple-800 hover:bg-purple-700 text-white text-sm font-semibold"
          >
            {j.nombre}
          </button>
        </div>
        <button phx-click="cancelar_seleccion_poder" class="w-full mt-2 py-1 text-purple-300 text-xs hover:text-white">
          Cancelar
        </button>
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

  defp otros_jugadores_activos(sala, nombre_propio) do
    Enum.filter(sala.jugadores, fn j -> j.nombre != nombre_propio and j.vidas > 0 end)
  end

  defp icono_poder("congelar"), do: "[congelar]"
  defp icono_poder("robar_puntos"), do: "[robar]"
  defp icono_poder("escudo"), do: "[escudo]"
  defp icono_poder("bomba_dirigida"), do: "[dirigir]"

  defp nombre_poder("congelar"), do: "Congelar tiempo"
  defp nombre_poder("robar_puntos"), do: "Robar puntos"
  defp nombre_poder("escudo"), do: "Escudo"
  defp nombre_poder("bomba_dirigida"), do: "Bomba dirigida"

  defp texto_seleccion("robar_puntos"), do: "Elige a quien robarle 10 puntos"
  defp texto_seleccion("bomba_dirigida"), do: "Elige a quien le pasaras la bomba si respondes bien"

  defp texto_evento("doble_puntos"), do: "Evento: Puntos dobles esta ronda"
  defp texto_evento("ronda_relampago"), do: "Evento: Ronda relampago"
end
