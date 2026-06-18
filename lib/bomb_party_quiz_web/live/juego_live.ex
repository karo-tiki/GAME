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
    <%= if @sala.estado == "finalizado" do %>
      {render_fin(assigns)}
    <% else %>
      {render_juego(assigns)}
    <% end %>
    """
  end

  defp render_fin(assigns) do
    ~H"""
    <div class="min-h-screen bg-neutral-950 flex items-center justify-center px-4"
         style={"background-image: url('#{fondo_tematica(@sala.tematica)}'); background-size: cover; background-position: center;"}>
      <div class="bg-green-900/90 border-4 border-green-700 rounded-2xl p-10 text-center max-w-md w-full shadow-2xl">
        <p class="text-5xl mb-4">🏆</p>
        <%= if @sala.ganador do %>
          <h1 class="text-3xl font-black text-white mb-2">
            Ganador: <span class="text-yellow-300">{@sala.ganador}</span>
          </h1>
        <% else %>
          <h1 class="text-2xl font-black text-white">La partida termino sin ganador</h1>
        <% end %>
        <div class="mt-6 bg-green-950/80 rounded-xl p-4">
          <p class="text-green-300 text-sm mb-3 font-bold">Marcador final</p>
          <div :for={j <- Enum.sort_by(@sala.jugadores, & -&1.puntos)} class="flex items-center gap-3 py-2 border-b border-green-800/50 last:border-0">
            <img src={j.avatar} class="w-8 h-8 rounded-full object-cover" />
            <span class="text-white flex-1 text-left">{j.nombre}</span>
            <span class="text-yellow-300 font-bold">{j.puntos} pts</span>
          </div>
        </div>
        <a href="/" class="inline-block mt-6 px-6 py-3 rounded-xl bg-orange-500 hover:bg-orange-400 text-neutral-950 font-bold transition">
          Volver al inicio
        </a>
      </div>
    </div>
    """
  end

  defp render_juego(assigns) do
    ~H"""
    <div class="relative w-full overflow-hidden"
         style={"min-height: 100vh; background-image: url('#{fondo_tematica(@sala.tematica)}'); background-size: cover; background-position: center top;"}>

      <!-- Evento de ronda (banner arriba) -->
      <div :if={@evento_anuncio} class="absolute top-2 left-1/2 -translate-x-1/2 z-30 bg-purple-900/90 border border-purple-400 rounded-xl px-6 py-2 text-purple-100 font-bold text-sm shadow-lg">
        {texto_evento(@evento_anuncio)}
      </div>

      <!-- PIZARRA: posicionada encima de la pizarra real de la imagen -->
      <!-- La pizarra esta aprox en el centro superior de la imagen -->
      <div class="absolute z-20"
           style="top: 3%; left: 22%; width: 56%; min-height: 52%;">

        <!-- Contenido de la pizarra: pregunta, timer, opciones -->
        <div class="w-full h-full bg-green-900/30 rounded-lg p-4 flex flex-col items-center justify-start">

          <!-- Flash de resultado -->
          <div :if={@flash_resultado} class="w-full mb-2">
            <%= case @flash_resultado do %>
              <% {"correcta", jugador} -> %>
                <p class="text-green-300 font-bold text-center text-sm drop-shadow">
                  {jugador} respondio correctamente
                </p>
              <% {"incorrecta", jugador} -> %>
                <p class="text-red-300 font-bold text-center text-sm drop-shadow">
                  {jugador} fallo y perdio una vida
                </p>
              <% {"poder_ganado", mensaje} -> %>
                <p class="text-purple-200 font-bold text-center text-sm drop-shadow">{mensaje}</p>
              <% {"poder_usado", mensaje} -> %>
                <p class="text-cyan-200 font-bold text-center text-sm drop-shadow">{mensaje}</p>
            <% end %>
          </div>

          <%= if @sala.pregunta_actual do %>
            <!-- Quien tiene la bomba -->
            <p class="text-green-200/80 text-xs mb-1 drop-shadow">Le toca a</p>
            <p class="text-white font-black text-lg drop-shadow mb-3">
              {@sala.jugador_con_bomba}
            </p>

            <!-- Timer: numero + barra -->
            <div class="w-full mb-3">
              <p class={[
                "text-center text-3xl font-black mb-1 drop-shadow",
                @tiempo_restante <= 3 && "text-red-300 animate-pulse",
                @tiempo_restante > 3 && "text-white"
              ]}>
                {@tiempo_restante}s
              </p>
              <div class="w-full h-2 bg-green-950/60 rounded-full overflow-hidden">
                <div
                  class={[
                    "h-full transition-all duration-1000 ease-linear rounded-full",
                    @tiempo_restante <= 3 && "bg-red-400",
                    @tiempo_restante > 3 && "bg-yellow-300"
                  ]}
                  style={"width: #{porcentaje_tiempo(@tiempo_restante, @sala.pregunta_actual)}%"}
                >
                </div>
              </div>
            </div>

            <!-- Pregunta -->
            <p class="text-white font-bold text-center text-base drop-shadow mb-4 leading-snug px-2">
              {@sala.pregunta_actual["pregunta"]}
            </p>

            <!-- Opciones o campo de texto -->
            <%= if @nombre == @sala.jugador_con_bomba do %>
              <%= if @sala.pregunta_actual["tipo"] == "seleccion" do %>
                <div class="grid grid-cols-2 gap-2 w-full">
                  <button
                    :for={opcion <- @sala.pregunta_actual["opciones"]}
                    phx-click="elegir_opcion"
                    phx-value-opcion={opcion}
                    class="py-2 px-3 rounded-lg bg-white/20 hover:bg-white/40 text-white font-semibold text-sm transition border border-white/30 drop-shadow"
                  >
                    {opcion}
                  </button>
                </div>
              <% else %>
                <form phx-submit="enviar_respuesta" phx-change="actualizar_respuesta" class="flex gap-2 w-full">
                  <input
                    type="text"
                    name="respuesta"
                    value={@respuesta}
                    autocomplete="off"
                    autofocus
                    placeholder="Escribe tu respuesta..."
                    class="flex-1 px-3 py-2 rounded-lg bg-white/20 text-white placeholder-white/50 border border-white/30 outline-none text-sm"
                  />
                  <button type="submit" class="px-4 py-2 rounded-lg bg-orange-500 hover:bg-orange-400 text-white font-bold text-sm transition">
                    Enviar
                  </button>
                </form>
              <% end %>
            <% else %>
              <p class="text-green-200/70 text-sm text-center drop-shadow">
                {@sala.jugador_con_bomba} esta respondiendo...
              </p>
            <% end %>
          <% end %>
        </div>
      </div>

      <!-- Selector de objetivo para poderes -->
      <div :if={@poder_seleccionado} class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-40 bg-purple-950/95 border border-purple-500 rounded-2xl p-5 w-72 shadow-2xl">
        <p class="text-purple-200 text-sm text-center mb-3 font-bold">
          {texto_seleccion(@poder_seleccionado)}
        </p>
        <div class="grid grid-cols-2 gap-2">
          <button
            :for={j <- otros_jugadores_activos(@sala, @nombre)}
            phx-click="elegir_objetivo"
            phx-value-objetivo={j.nombre}
            class="flex items-center gap-2 py-2 px-3 rounded-lg bg-purple-800 hover:bg-purple-700 text-white text-sm font-semibold"
          >
            <img src={j.avatar} class="w-7 h-7 rounded-full object-cover" />
            {j.nombre}
          </button>
        </div>
        <button phx-click="cancelar_seleccion_poder" class="w-full mt-3 py-1 text-purple-300 text-xs hover:text-white">
          Cancelar
        </button>
      </div>

      <!-- BARRA DE JUGADORES en la parte inferior -->
      <div class="absolute bottom-0 left-0 right-0 z-20 p-3"
           style="background: linear-gradient(to top, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.4) 70%, transparent 100%);">
        <div class="max-w-4xl mx-auto grid grid-cols-4 gap-3">
          <div
            :for={jugador <- @sala.jugadores}
            class={[
              "rounded-2xl p-2 text-center border-2 transition",
              jugador.nombre == @sala.jugador_con_bomba && "border-orange-400 bg-orange-900/60 scale-105",
              jugador.nombre != @sala.jugador_con_bomba && "border-neutral-700/50 bg-neutral-900/60",
              jugador.vidas == 0 && "opacity-40"
            ]}
          >
            <div class="relative inline-block">
              <img
                src={jugador.avatar}
                alt={jugador.nombre}
                class="w-12 h-12 rounded-full object-cover mx-auto border-2 border-white/20"
              />
              <span :if={jugador.nombre == @sala.jugador_con_bomba}
                class="absolute -top-1 -right-1 text-sm">💣</span>
            </div>
            <p class="text-white font-semibold text-xs truncate mt-1">{jugador.nombre}</p>
            <p class="text-sm mt-0.5">
              <%= for n <- 1..3 do %>
                <%= if n <= jugador.vidas do %>❤️<% else %>🖤<% end %>
              <% end %>
            </p>
            <p class="text-yellow-400 text-xs font-bold">{jugador.puntos} pts</p>
            <p :if={jugador.racha > 0} class="text-orange-300 text-xs">racha x{jugador.racha}</p>
            <p :if={jugador.escudo_activo} class="text-cyan-300 text-xs">escudo</p>

            <!-- Poderes clickeables -->
            <div :if={jugador.poderes != []} class="flex justify-center gap-1 mt-1 flex-wrap">
              <button
                :for={poder <- jugador.poderes}
                type="button"
                disabled={jugador.nombre != @nombre or jugador.nombre != @sala.jugador_con_bomba}
                phx-click="click_poder"
                phx-value-poder={poder}
                class={[
                  "text-xs px-1.5 py-0.5 rounded border",
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
      </div>
    </div>
    """
  end

  defp fondo_tematica("matematica"), do: "/images/fondo_matematica.png"
  defp fondo_tematica("cultura_general"), do: "/images/fondo_cultura.jpeg"
  defp fondo_tematica("programacion"), do: "/images/fondo_programacion.jpeg"
  defp fondo_tematica(_), do: "/images/fondo_matematica.png"

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
