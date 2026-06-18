defmodule BombPartyQuiz.Sala do
  @moduledoc """
  GenServer que representa UNA sala de juego (una partida).

  Cada sala es un proceso independiente con su propio estado:
  jugadores, vidas, quién tiene la bomba, la pregunta actual y el
  temporizador. Cuando algo cambia, se avisa a todos los LiveViews
  conectados a esa sala vía Phoenix.PubSub.
  """
  use GenServer
  alias BombPartyQuiz.Preguntas
  alias Phoenix.PubSub

  @minimo_jugadores 3
  @maximo_jugadores 4
  @vidas_iniciales 3
  @pubsub BombPartyQuiz.PubSub

  defstruct codigo: nil,
            anfitrion: nil,
            tematica: nil,
            jugadores: [],
            estado: :esperando,
            jugador_con_bomba: nil,
            pregunta_actual: nil,
            tiempo_restante: 0,
            ganador: nil,
            temporizador_ref: nil

  # ============================================================
  # API PÚBLICA — funciones que los LiveViews van a llamar
  # ============================================================

  def start_link(codigo) do
    GenServer.start_link(__MODULE__, codigo, name: nombre_proceso(codigo))
  end

  def nombre_proceso(codigo) do
    {:via, Registry, {BombPartyQuiz.SalaRegistry, codigo}}
  end

  def existe?(codigo) do
    case Registry.lookup(BombPartyQuiz.SalaRegistry, codigo) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  def crear(codigo, nombre_anfitrion, tematica) do
    GenServer.call(nombre_proceso(codigo), {:crear, nombre_anfitrion, tematica})
  end

  def unirse(codigo, nombre_jugador) do
    GenServer.call(nombre_proceso(codigo), {:unirse, nombre_jugador})
  end

  def iniciar_partida(codigo) do
    GenServer.call(nombre_proceso(codigo), :iniciar_partida)
  end

  def responder(codigo, nombre_jugador, respuesta) do
    GenServer.call(nombre_proceso(codigo), {:responder, nombre_jugador, respuesta})
  end

  def desconectar(codigo, nombre_jugador) do
    GenServer.cast(nombre_proceso(codigo), {:desconectar, nombre_jugador})
  end

  def estado(codigo) do
    GenServer.call(nombre_proceso(codigo), :estado)
  end

  def topic(codigo), do: "sala:#{codigo}"

  # ============================================================
  # CALLBACKS DEL GENSERVER — acá vive la lógica real
  # ============================================================

  @impl true
  def init(codigo) do
    {:ok, %__MODULE__{codigo: codigo}}
  end

  @impl true
  def handle_call({:crear, nombre_anfitrion, tematica}, _from, sala) do
    jugador = nuevo_jugador(nombre_anfitrion)
    sala = %{sala | anfitrion: nombre_anfitrion, tematica: tematica, jugadores: [jugador]}
    {:reply, {:ok, sala}, sala}
  end

  def handle_call({:unirse, nombre_jugador}, _from, sala) do
    cond do
      sala.estado != :esperando ->
        {:reply, {:error, :partida_ya_iniciada}, sala}

      length(sala.jugadores) >= @maximo_jugadores ->
        {:reply, {:error, :sala_llena}, sala}

      Enum.any?(sala.jugadores, &(&1.nombre == nombre_jugador)) ->
        {:reply, {:error, :nombre_en_uso}, sala}

      true ->
        jugador = nuevo_jugador(nombre_jugador)
        sala = %{sala | jugadores: sala.jugadores ++ [jugador]}
        anunciar(sala, {:jugadores_actualizados, sala})
        {:reply, {:ok, sala}, sala}
    end
  end

  def handle_call(:iniciar_partida, _from, sala) do
    if length(sala.jugadores) < @minimo_jugadores do
      {:reply, {:error, :faltan_jugadores}, sala}
    else
      sala = iniciar_turno(%{sala | estado: :jugando})
      anunciar(sala, {:partida_iniciada, sala})
      {:reply, {:ok, sala}, sala}
    end
  end

  def handle_call({:responder, nombre_jugador, respuesta}, _from, sala) do
    if sala.jugador_con_bomba != nombre_jugador or sala.estado != :jugando do
      {:reply, {:error, :no_es_tu_turno}, sala}
    else
      correcta? = Preguntas.respuesta_correcta?(sala.pregunta_actual, respuesta)
      sala = cancelar_temporizador(sala)
      sala = procesar_resultado(sala, correcta?)
      {:reply, {:ok, correcta?}, sala}
    end
  end

  def handle_call(:estado, _from, sala) do
    {:reply, sala, sala}
  end

  @impl true
  def handle_cast({:desconectar, nombre_jugador}, sala) do
    sala = marcar_sin_vidas(sala, nombre_jugador)

    sala =
      if sala.estado == :jugando and sala.jugador_con_bomba == nombre_jugador do
        sala = cancelar_temporizador(sala)
        procesar_resultado(sala, false)
      else
        verificar_fin_de_partida(sala)
      end

    anunciar(sala, {:jugadores_actualizados, sala})
    {:noreply, sala}
  end

  @impl true
  def handle_info(:tiempo_agotado, sala) do
    sala = procesar_resultado(sala, false)
    {:noreply, sala}
  end

  # ============================================================
  # LÓGICA INTERNA DEL JUEGO
  # ============================================================

  defp nuevo_jugador(nombre) do
    %{nombre: nombre, vidas: @vidas_iniciales, conectado: true}
  end

  defp iniciar_turno(sala) do
    jugador_elegido =
      sala.jugadores
      |> jugadores_activos()
      |> Enum.random()

    pregunta = Preguntas.aleatoria(sala.tematica)
    segundos = Preguntas.tiempo_segundos(pregunta)

    ref = Process.send_after(self(), :tiempo_agotado, segundos * 1000)

    sala = %{
      sala
      | jugador_con_bomba: jugador_elegido.nombre,
        pregunta_actual: pregunta,
        tiempo_restante: segundos,
        temporizador_ref: ref
    }

    anunciar(sala, {:nuevo_turno, sala})
    sala
  end

  defp jugadores_activos(jugadores) do
    Enum.filter(jugadores, fn j -> j.vidas > 0 and j.conectado end)
  end

  defp cancelar_temporizador(sala) do
    if sala.temporizador_ref, do: Process.cancel_timer(sala.temporizador_ref)
    %{sala | temporizador_ref: nil}
  end

  defp procesar_resultado(sala, correcta?) do
    sala =
      if correcta? do
        anunciar(sala, {:respuesta_correcta, sala.jugador_con_bomba})
        sala
      else
        sala = quitar_vida(sala, sala.jugador_con_bomba)
        anunciar(sala, {:respuesta_incorrecta, sala.jugador_con_bomba, sala})
        sala
      end

    sala = verificar_fin_de_partida(sala)

    if sala.estado == :jugando do
      iniciar_turno(sala)
    else
      sala
    end
  end

  defp quitar_vida(sala, nombre_jugador) do
    jugadores =
      Enum.map(sala.jugadores, fn j ->
        if j.nombre == nombre_jugador, do: %{j | vidas: max(j.vidas - 1, 0)}, else: j
      end)

    %{sala | jugadores: jugadores}
  end

  defp marcar_sin_vidas(sala, nombre_jugador) do
    jugadores =
      Enum.map(sala.jugadores, fn j ->
        if j.nombre == nombre_jugador, do: %{j | vidas: 0, conectado: false}, else: j
      end)

    %{sala | jugadores: jugadores}
  end

  defp verificar_fin_de_partida(sala) do
    activos = jugadores_activos(sala.jugadores)

    case activos do
      [unico_ganador] ->
        sala = %{
          sala
          | estado: :finalizado,
            ganador: unico_ganador.nombre,
            jugador_con_bomba: nil,
            pregunta_actual: nil
        }

        anunciar(sala, {:partida_finalizada, sala})
        sala

      [] ->
        sala = %{sala | estado: :finalizado, ganador: nil, jugador_con_bomba: nil}
        anunciar(sala, {:partida_finalizada, sala})
        sala

      _varios ->
        sala
    end
  end

  defp anunciar(sala, mensaje) do
    PubSub.broadcast(@pubsub, topic(sala.codigo), mensaje)
  end
end
