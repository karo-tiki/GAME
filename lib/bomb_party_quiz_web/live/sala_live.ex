defmodule BombPartyQuizWeb.SalaLive do
  use BombPartyQuizWeb, :live_view

  alias BombPartyQuiz.Sala
  alias Phoenix.PubSub

  @pubsub BombPartyQuiz.PubSub
  @minimo_jugadores 3
  @maximo_jugadores 4

  @impl true
  def mount(%{"codigo" => codigo}, _session, socket) do
    {:ok, socket |> assign(:codigo, codigo) |> assign(:cargado, false)}
  end

  # Leemos los query params (?nombre=...&anfitrion=true) en handle_params,
  # que es donde Phoenix LiveView los entrega de forma confiable.
  @impl true
  def handle_params(params, _uri, socket) do
    codigo = socket.assigns.codigo
    nombre = Map.get(params, "nombre", "")
    es_anfitrion = Map.get(params, "anfitrion") == "true"

    cond do
      socket.assigns[:cargado] ->
        {:noreply, socket}

      not Sala.existe?(codigo) ->
        {:noreply,
         socket
         |> put_flash(:error, "Esa sala ya no existe")
         |> push_navigate(to: ~p"/")}

      true ->
        # Si NO es el anfitrión, todavía no se ha unido -> lo unimos ahora.
        resultado_union =
          if es_anfitrion do
            {:ok, Sala.estado(codigo)}
          else
            Sala.unirse(codigo, nombre)
          end

        case resultado_union do
          {:ok, sala} ->
            if connected?(socket) do
              PubSub.subscribe(@pubsub, Sala.topic(codigo))
            end

            {:noreply,
             socket
             |> assign(:cargado, true)
             |> assign(:nombre, nombre)
             |> assign(:sala, sala)
             |> assign(:minimo, @minimo_jugadores)
             |> assign(:maximo, @maximo_jugadores)}

          {:error, motivo} ->
            {:noreply,
             socket
             |> put_flash(:error, mensaje_error(motivo))
             |> push_navigate(to: ~p"/")}
        end
    end
  end

  defp mensaje_error("sala_llena"), do: "Esa sala ya está llena (máximo 4 jugadores)"
  defp mensaje_error("nombre_en_uso"), do: "Ese nombre ya está en uso en esta sala"
  defp mensaje_error("partida_ya_iniciada"), do: "Esa partida ya comenzó"
  defp mensaje_error(_), do: "No se pudo unir a la sala"

  @impl true
  def handle_event("iniciar_partida", _params, socket) do
    case Sala.iniciar_partida(socket.assigns.codigo) do
      {:ok, _sala} ->
        {:noreply, socket}

      {:error, "faltan_jugadores"} ->
        {:noreply, put_flash(socket, :error, "Necesitas al menos #{@minimo_jugadores} jugadores")}
    end
  end

  @impl true
  def handle_info({"jugadores_actualizados", sala}, socket) do
    {:noreply, assign(socket, :sala, sala)}
  end

  def handle_info({"partida_iniciada", sala}, socket) do
    nombre = socket.assigns.nombre
    {:noreply, push_navigate(socket, to: ~p"/sala/#{sala.codigo}/jugar?nombre=#{nombre}")}
  end

  def handle_info(_otro, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-neutral-950 flex items-center justify-center px-4 py-8">
      <div class="w-full max-w-lg">

        <div class="text-center mb-8">
          <p class="text-neutral-500 text-sm uppercase tracking-widest mb-1">Sala de espera</p>
          <div class="inline-flex items-center gap-3 bg-neutral-900 border border-neutral-700 rounded-2xl px-6 py-3">
            <span class="text-neutral-400 text-sm">Codigo:</span>
            <span class="text-3xl font-black text-white font-mono tracking-widest">{@sala.codigo}</span>
          </div>
          <p class="text-neutral-600 text-xs mt-2">Comparte este codigo con los demas jugadores</p>
        </div>

        <div class="bg-neutral-900 border border-neutral-800 rounded-3xl p-6 shadow-2xl mb-4">
          <div class="flex items-center justify-between mb-5">
            <h2 class="text-white font-bold text-lg">Jugadores</h2>
            <div class="flex items-center gap-1">
              <span class="text-orange-400 font-bold">{length(@sala.jugadores)}</span>
              <span class="text-neutral-500">/</span>
              <span class="text-neutral-400">{@maximo}</span>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3 mb-6">
            <div
              :for={jugador <- @sala.jugadores}
              class="flex items-center gap-3 bg-neutral-800 rounded-2xl p-3 border border-neutral-700"
            >
              <img
                src={jugador.avatar}
                alt={jugador.nombre}
                class="w-12 h-12 rounded-full object-cover border-2 border-orange-400/50"
              />
              <div class="min-w-0">
                <p class="text-white font-semibold text-sm truncate">{jugador.nombre}</p>
                <p :if={jugador.nombre == @sala.anfitrion} class="text-orange-400 text-xs">
                  anfitrion
                </p>
                <p :if={jugador.nombre != @sala.anfitrion} class="text-green-400 text-xs">
                  conectado
                </p>
              </div>
            </div>

            <div
              :for={_n <- 1..(@maximo - length(@sala.jugadores))}
              class="flex items-center gap-3 bg-neutral-800/40 rounded-2xl p-3 border border-neutral-800 border-dashed"
            >
              <div class="w-12 h-12 rounded-full bg-neutral-700/40 flex items-center justify-center">
                <span class="text-neutral-600 text-xl">?</span>
              </div>
              <p class="text-neutral-600 text-sm">Esperando...</p>
            </div>
          </div>

          <div class="flex items-center justify-center gap-2 mb-5 bg-neutral-800/50 rounded-xl py-2 px-4">
            <span class="text-neutral-400 text-sm">Tematica:</span>
            <span class="text-white font-semibold text-sm">{nombre_tematica(@sala.tematica)}</span>
          </div>

          <%= if @nombre == @sala.anfitrion do %>
            <button
              phx-click="iniciar_partida"
              disabled={length(@sala.jugadores) < @minimo}
              class="w-full py-4 rounded-2xl bg-orange-500 hover:bg-orange-400 disabled:bg-neutral-700 disabled:text-neutral-500 text-neutral-950 font-black text-lg transition"
            >
              <%= if length(@sala.jugadores) < @minimo do %>
                Esperando jugadores ({@minimo - length(@sala.jugadores)} mas)
              <% else %>
                Iniciar partida
              <% end %>
            </button>
          <% else %>
            <div class="text-center py-3">
              <p class="text-neutral-400 text-sm">Esperando al anfitrion...</p>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp nombre_tematica("matematica"), do: "Matematica"
  defp nombre_tematica("cultura_general"), do: "Cultura General"
  defp nombre_tematica("programacion"), do: "Lenguajes de Programacion"
end
