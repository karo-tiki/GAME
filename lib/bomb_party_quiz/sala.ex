defmodule BombPartyQuiz.Sala do
  @moduledoc """
  GenServer que representa UNA sala de juego (una partida).

  Siguiendo el requisito del curso, todos los datos de dominio
  (estado de la sala, nombres de poderes, eventos, mensajes internos
  y mensajes de PubSub) se representan como strings, no como atomos.
  Los unicos atomos presentes son los exigidos por el protocolo OTP
  de Elixir: :ok, :error, :reply, :noreply, :via.
  """
  use GenServer
  alias BombPartyQuiz.Preguntas
  alias Phoenix.PubSub

  @minimo_jugadores 3
  @maximo_jugadores 4
  @vidas_iniciales 3
  @racha_para_poder 3
  @turnos_por_evento 5
  @puntos_base 10
  @puntos_robados 10
  @bono_congelar 5
  @pubsub BombPartyQuiz.PubSub

  @poderes_disponibles ["congelar", "robar_puntos", "escudo", "bomba_dirigida"]

  defstruct codigo: nil,
            anfitrion: nil,
            tematica: nil,
            jugadores: [],
            estado: "esperando",
            jugador_con_bomba: nil,
            pregunta_actual: nil,
            tiempo_restante: 0,
            ganador: nil,
            temporizador_ref: nil,
            turnos_completados: 0,
            evento_actual: nil,
            multiplicador_puntos: 1,
            objetivo_bomba_dirigida: nil

  # ============================================================
  # API PÚBLICA
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
    GenServer.call(nombre_proceso(codigo), {"crear", nombre_anfitrion, tematica})
  end

  def unirse(codigo, nombre_jugador) do
    GenServer.call(nombre_proceso(codigo), {"unirse", nombre_jugador})
  end

  def iniciar_partida(codigo) do
    GenServer.call(nombre_proceso(codigo), "iniciar_partida")
  end

  def responder(codigo, nombre_jugador, respuesta) do
    GenServer.call(nombre_proceso(codigo), {"responder", nombre_jugador, respuesta})
  end

  @doc "Activa un poder guardado. `objetivo` se usa solo para robar_puntos y bomba_dirigida."
  def usar_poder(codigo, nombre_jugador, poder, objetivo \\ nil) do
    GenServer.call(nombre_proceso(codigo), {"usar_poder", nombre_jugador, poder, objetivo})
  end

  def desconectar(codigo, nombre_jugador) do
    GenServer.cast(nombre_proceso(codigo), {"desconectar", nombre_jugador})
  end

  def estado(codigo) do
    GenServer.call(nombre_proceso(codigo), "estado")
  end

  def topic(codigo), do: "sala:#{codigo}"

  # ============================================================
  # CALLBACKS
  # ============================================================

  @impl true
  def init(codigo) do
    {:ok, %__MODULE__{codigo: codigo}}
  end

  @impl true
  def handle_call({"crear", nombre_anfitrion, tematica}, _from, sala) do
    jugador = nuevo_jugador(nombre_anfitrion, 1)
    sala = %{sala | anfitrion: nombre_anfitrion, tematica: tematica, jugadores: [jugador]}
    {:reply, {:ok, sala}, sala}
  end

  def handle_call({"unirse", nombre_jugador}, _from, sala) do
    cond do
      sala.estado != "esperando" ->
        {:reply, {:error, "partida_ya_iniciada"}, sala}

      length(sala.jugadores) >= @maximo_jugadores ->
        {:reply, {:error, "sala_llena"}, sala}

      Enum.any?(sala.jugadores, &(&1.nombre == nombre_jugador)) ->
        {:reply, {:error, "nombre_en_uso"}, sala}

      true ->
        posicion = length(sala.jugadores) + 1
        jugador = nuevo_jugador(nombre_jugador, posicion)
        sala = %{sala | jugadores: sala.jugadores ++ [jugador]}
        anunciar(sala, {"jugadores_actualizados", sala})
        {:reply, {:ok, sala}, sala}
    end
  end

  def handle_call("iniciar_partida", _from, sala) do
    if length(sala.jugadores) < @minimo_jugadores do
      {:reply, {:error, "faltan_jugadores"}, sala}
    else
      sala = iniciar_turno(%{sala | estado: "jugando"})
      anunciar(sala, {"partida_iniciada", sala})
      {:reply, {:ok, sala}, sala}
    end
  end

  def handle_call({"responder", nombre_jugador, respuesta}, _from, sala) do
    if sala.jugador_con_bomba != nombre_jugador or sala.estado != "jugando" do
      {:reply, {:error, "no_es_tu_turno"}, sala}
    else
      correcta? = Preguntas.respuesta_correcta?(sala.pregunta_actual, respuesta)
      sala = cancelar_temporizador(sala)
      sala = procesar_resultado(sala, correcta?)
      {:reply, {:ok, correcta?}, sala}
    end
  end

  def handle_call({"usar_poder", nombre_jugador, poder, objetivo}, _from, sala) do
    cond do
      sala.jugador_con_bomba != nombre_jugador ->
        {:reply, {:error, "no_es_tu_turno"}, sala}

      not tiene_poder?(sala, nombre_jugador, poder) ->
        {:reply, {:error, "no_tienes_ese_poder"}, sala}

      true ->
        sala = consumir_poder(sala, nombre_jugador, poder)
        sala = aplicar_poder(sala, nombre_jugador, poder, objetivo)
        anunciar(sala, {"jugadores_actualizados", sala})

        if poder != "congelar" do
          anunciar(sala, {"poder_usado", nombre_jugador, poder})
        end

        {:reply, {:ok, sala}, sala}
    end
  end

  def handle_call("estado", _from, sala) do
    {:reply, sala, sala}
  end

  @impl true
  def handle_cast({"desconectar", nombre_jugador}, sala) do
    sala = marcar_sin_vidas(sala, nombre_jugador)

    sala =
      if sala.estado == "jugando" and sala.jugador_con_bomba == nombre_jugador do
        sala = cancelar_temporizador(sala)
        procesar_resultado(sala, false)
      else
        verificar_fin_de_partida(sala)
      end

    anunciar(sala, {"jugadores_actualizados", sala})
    {:noreply, sala}
  end

  @impl true
  def handle_info("tiempo_agotado", sala) do
    sala = procesar_resultado(sala, false)
    {:noreply, sala}
  end

  # ============================================================
  # JUGADOR — estructura base
  # ============================================================

  defp nuevo_jugador(nombre, posicion) do
    %{
      nombre: nombre,
      vidas: @vidas_iniciales,
      conectado: true,
      puntos: 0,
      racha: 0,
      poderes: [],
      escudo_activo: false,
      bono_tiempo_propio: 0,
      avatar: "/images/gato#{posicion}.jpeg"
    }
  end

  # ============================================================
  # TURNOS
  # ============================================================

  defp iniciar_turno(sala) do
    # Si alguien activo "bomba dirigida" en el turno anterior, ese jugador
    # ya quedo fijado como objetivo_bomba_dirigida; si no, se elige al azar.
    jugador_elegido_nombre =
      sala.objetivo_bomba_dirigida ||
        (sala.jugadores
         |> jugadores_activos()
         |> Enum.random()
         |> Map.get(:nombre))

    pregunta = Preguntas.aleatoria(sala.tematica)
    segundos_base = Preguntas.tiempo_segundos(pregunta)

    bono = obtener_bono_tiempo(sala, jugador_elegido_nombre)
    segundos = segundos_base + bono

    ref = Process.send_after(self(), "tiempo_agotado", segundos * 1000)

    sala = %{
      sala
      | jugador_con_bomba: jugador_elegido_nombre,
        pregunta_actual: pregunta,
        tiempo_restante: segundos,
        temporizador_ref: ref,
        objetivo_bomba_dirigida: nil
    }
    |> limpiar_bono_tiempo(jugador_elegido_nombre)

    anunciar(sala, {"nuevo_turno", sala})
    sala
  end

  defp jugadores_activos(jugadores) do
    Enum.filter(jugadores, fn j -> j.vidas > 0 and j.conectado end)
  end

  defp cancelar_temporizador(sala) do
    if sala.temporizador_ref, do: Process.cancel_timer(sala.temporizador_ref)
    %{sala | temporizador_ref: nil}
  end

  defp obtener_bono_tiempo(sala, nombre_jugador) do
    case Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador)) do
      nil -> 0
      jugador -> jugador.bono_tiempo_propio
    end
  end

  defp limpiar_bono_tiempo(sala, nombre_jugador) do
    actualizar_jugador(sala, nombre_jugador, fn j -> %{j | bono_tiempo_propio: 0} end)
  end

  # ============================================================
  # RESULTADO DE UNA RESPUESTA
  # ============================================================

  defp procesar_resultado(sala, correcta?) do
    nombre = sala.jugador_con_bomba

    sala =
      if correcta? do
        sala
        |> sumar_puntos(nombre)
        |> sumar_racha(nombre)
        |> tap_anunciar({"respuesta_correcta", nombre})
      else
        sala
        |> aplicar_falla(nombre)
        |> tap_anunciar_sala({"respuesta_incorrecta", nombre})
      end

    sala = incrementar_turnos(sala)
    sala = verificar_fin_de_partida(sala)

    if sala.estado == "jugando" do
      iniciar_turno(sala)
    else
      sala
    end
  end

  defp tap_anunciar(sala, mensaje) do
    anunciar(sala, mensaje)
    sala
  end

  defp tap_anunciar_sala(sala, {tipo, nombre}) do
    anunciar(sala, {tipo, nombre, sala})
    sala
  end

  defp sumar_puntos(sala, nombre_jugador) do
    segundos_sobrantes = sala.tiempo_restante
    puntos = (@puntos_base + segundos_sobrantes) * sala.multiplicador_puntos

    actualizar_jugador(sala, nombre_jugador, fn j -> %{j | puntos: j.puntos + puntos} end)
  end

  # Suma 1 a la racha; si llega al umbral, otorga un poder aleatorio y resetea la racha.
  defp sumar_racha(sala, nombre_jugador) do
    jugador = Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador))
    nueva_racha = jugador.racha + 1

    if nueva_racha >= @racha_para_poder do
      poder = Enum.random(@poderes_disponibles)

      sala = actualizar_jugador(sala, nombre_jugador, fn j ->
        %{j | racha: 0, poderes: j.poderes ++ [poder]}
      end)

      anunciar(sala, {"poder_ganado", nombre_jugador, poder})
      sala
    else
      actualizar_jugador(sala, nombre_jugador, fn j -> %{j | racha: nueva_racha} end)
    end
  end

  # Si falla: el escudo absorbe la perdida de vida una sola vez; si no tiene
  # escudo, pierde vida normalmente. En ambos casos, la racha se resetea a 0.
  defp aplicar_falla(sala, nombre_jugador) do
    jugador = Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador))

    if jugador.escudo_activo do
      actualizar_jugador(sala, nombre_jugador, fn j -> %{j | racha: 0, escudo_activo: false} end)
    else
      sala
      |> quitar_vida(nombre_jugador)
      |> actualizar_jugador(nombre_jugador, fn j -> %{j | racha: 0} end)
    end
  end

  defp quitar_vida(sala, nombre_jugador) do
    actualizar_jugador(sala, nombre_jugador, fn j -> %{j | vidas: max(j.vidas - 1, 0)} end)
  end

  defp marcar_sin_vidas(sala, nombre_jugador) do
    actualizar_jugador(sala, nombre_jugador, fn j -> %{j | vidas: 0, conectado: false} end)
  end

  defp actualizar_jugador(sala, nombre_jugador, fun) do
    jugadores =
      Enum.map(sala.jugadores, fn j ->
        if j.nombre == nombre_jugador, do: fun.(j), else: j
      end)

    %{sala | jugadores: jugadores}
  end

  # ============================================================
  # PODERES
  # ============================================================

  defp tiene_poder?(sala, nombre_jugador, poder) do
    case Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador)) do
      nil -> false
      jugador -> poder in jugador.poderes
    end
  end

  defp consumir_poder(sala, nombre_jugador, poder) do
    actualizar_jugador(sala, nombre_jugador, fn j ->
      %{j | poderes: List.delete(j.poderes, poder)}
    end)
  end

  # congelar: efecto inmediato. Si lo usa el jugador que tiene la bomba en
  # este momento, se le agregan 5 segundos AL TEMPORIZADOR QUE YA ESTA
  # CORRIENDO: se cancela el timer actual y se reprograma con el tiempo
  # restante + el bono, y se avisa a las pantallas del nuevo tiempo.
  defp aplicar_poder(sala, nombre_jugador, "congelar", _objetivo) do
    if sala.jugador_con_bomba == nombre_jugador do
      sala = cancelar_temporizador(sala)
      nuevo_tiempo = sala.tiempo_restante + @bono_congelar

      ref = Process.send_after(self(), "tiempo_agotado", nuevo_tiempo * 1000)

      sala = %{sala | tiempo_restante: nuevo_tiempo, temporizador_ref: ref}
      anunciar(sala, {"tiempo_extendido", nombre_jugador, sala})
      sala
    else
      sala
    end
  end

  # robar_puntos: quita puntos al objetivo elegido y se los suma a quien usa el poder.
  defp aplicar_poder(sala, nombre_jugador, "robar_puntos", objetivo) when is_binary(objetivo) do
    sala
    |> actualizar_jugador(objetivo, fn j -> %{j | puntos: max(j.puntos - @puntos_robados, 0)} end)
    |> actualizar_jugador(nombre_jugador, fn j -> %{j | puntos: j.puntos + @puntos_robados} end)
  end

  defp aplicar_poder(sala, _nombre_jugador, "robar_puntos", _objetivo), do: sala

  # escudo: se activa y queda pendiente hasta la proxima vez que el jugador falle.
  defp aplicar_poder(sala, nombre_jugador, "escudo", _objetivo) do
    actualizar_jugador(sala, nombre_jugador, fn j -> %{j | escudo_activo: true} end)
  end

  # bomba_dirigida: si responde correctamente este turno, el o ella decide
  # a quien le pasa la bomba en vez de elegir al azar.
  defp aplicar_poder(sala, _nombre_jugador, "bomba_dirigida", objetivo) when is_binary(objetivo) do
    %{sala | objetivo_bomba_dirigida: objetivo}
  end

  defp aplicar_poder(sala, _nombre_jugador, "bomba_dirigida", _objetivo), do: sala

  # ============================================================
  # EVENTOS ALEATORIOS DE RONDA (cada @turnos_por_evento turnos)
  # ============================================================

  defp incrementar_turnos(sala) do
    turnos = sala.turnos_completados + 1

    if rem(turnos, @turnos_por_evento) == 0 do
      activar_evento_aleatorio(%{sala | turnos_completados: turnos})
    else
      %{sala | turnos_completados: turnos}
    end
  end

  defp activar_evento_aleatorio(sala) do
    evento = Enum.random(["doble_puntos", "ronda_relampago", "sin_evento"])

    sala =
      case evento do
        "doble_puntos" -> %{sala | multiplicador_puntos: 2, evento_actual: "doble_puntos"}
        "ronda_relampago" -> %{sala | evento_actual: "ronda_relampago"}
        "sin_evento" -> %{sala | multiplicador_puntos: 1, evento_actual: nil}
      end

    if evento != "sin_evento" do
      anunciar(sala, {"evento_activado", evento})
    end

    sala
  end

  # ============================================================
  # FIN DE PARTIDA
  # ============================================================

  defp verificar_fin_de_partida(sala) do
    activos = jugadores_activos(sala.jugadores)

    case activos do
      [unico_ganador] ->
        sala = %{
          sala
          | estado: "finalizado",
            ganador: unico_ganador.nombre,
            jugador_con_bomba: nil,
            pregunta_actual: nil
        }

        anunciar(sala, {"partida_finalizada", sala})
        sala

      [] ->
        sala = %{sala | estado: "finalizado", ganador: nil, jugador_con_bomba: nil}
        anunciar(sala, {"partida_finalizada", sala})
        sala

      _varios ->
        sala
    end
  end

  defp anunciar(sala, mensaje) do
    PubSub.broadcast(@pubsub, topic(sala.codigo), mensaje)
  end
end
