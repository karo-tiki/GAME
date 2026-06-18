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
    <div class="min-h-screen bg-gradient-to-b from-black via-neutral-900 to-red-950 flex items-center justify-center px-4">
      <div class="w-full max-w-md">
        <div class="text-center mb-6">
          <p class="text-neutral-400 text-sm">Código de la sala</p>
          <p class="text-4xl font-black text-white font-mono tracking-widest">{@sala.codigo}</p>
          <p class="text-neutral-500 text-xs mt-1">Compártelo con los demás jugadores</p>
        </div>

        <div class="bg-neutral-900/80 border border-red-900/50 rounded-2xl p-6 shadow-2xl shadow-red-950/50">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-white font-bold">Jugadores</h2>
            <span class="text-sm text-neutral-400">
              {length(@sala.jugadores)} / {@maximo}
            </span>
          </div>

          <ul class="space-y-2 mb-6">
            <li
              :for={jugador <- @sala.jugadores}
              class="flex items-center justify-between bg-neutral-800 rounded-lg px-4 py-2"
            >
              <span class="text-white font-medium">
                {jugador.nombre}
                <span :if={jugador.nombre == @sala.anfitrion} class="text-red-400 text-xs ml-1">
                  (anfitrión)
                </span>
              </span>
              <span class="text-green-400 text-xs">●conectado</span>
            </li>
          </ul>

          <div class="text-center text-sm text-neutral-400 mb-4">
            Temática: <span class="text-white font-semibold">{nombre_tematica(@sala.tematica)}</span>
          </div>

          <%= if @nombre == @sala.anfitrion do %>
            <button
              phx-click="iniciar_partida"
              disabled={length(@sala.jugadores) < @minimo}
              class="w-full py-3 rounded-xl bg-red-600 hover:bg-red-500 disabled:bg-neutral-700 disabled:text-neutral-500 text-white font-bold text-lg transition"
            >
              <%= if length(@sala.jugadores) < @minimo do %>
                Esperando jugadores ({@minimo - length(@sala.jugadores)} más)
              <% else %>
                Iniciar partida 💣
              <% end %>
            </button>
          <% else %>
            <p class="text-center text-neutral-400 text-sm">
              Esperando a que el anfitrión inicie la partida...
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp nombre_tematica("matematica"), do: "Matemática"
  defp nombre_tematica("cultura_general"), do: "Cultura General"
  defp nombre_tematica("programacion"), do: "Lenguajes de Programación"
end
