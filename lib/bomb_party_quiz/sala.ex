defmodule BombPartyQuiz.Sala do
  @moduledoc """
  GenServer que representa UNA sala de juego (una partida).

  Modo de juego: "respuesta libre". Hay UNA pregunta activa a la vez,
  pero NO esta asignada a un jugador especifico: cualquier jugador con
  vidas puede intentar responderla en el momento en que crea saber la
  respuesta. Si falla, pierde una vida y queda "fuera" de esa pregunta
  (no puede volver a intentarla), pero la pregunta sigue abierta para
  el resto hasta que alguien acierte, se acabe el tiempo, o ya todos
  hayan fallado.

  Como el GenServer procesa los mensajes uno a la vez (su buzon es
  secuencial), aunque varios jugadores respondan "al mismo tiempo"
  desde procesos distintos, el servidor los ordena de forma segura sin
  condiciones de carrera: el primer `responder` correcto que llega
  cierra la pregunta para todos los demas.

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

  @poderes_disponibles ["congelar", "robar_puntos", "escudo", "pista"]

  defstruct codigo: nil,
            anfitrion: nil,
            tematica: nil,
            jugadores: [],
            estado: "esperando",
            pregunta_actual: nil,
            tiempo_restante: 0,
            intentos_fallidos: [],
            opciones_ocultas: [],
            letra_revelada: nil,
            ganador: nil,
            temporizador_ref: nil,
            turnos_completados: 0,
            evento_actual: nil,
            multiplicador_puntos: 1

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

  @doc "Cualquier jugador con vidas puede intentar responder la pregunta activa."
  def responder(codigo, nombre_jugador, respuesta) do
    GenServer.call(nombre_proceso(codigo), {"responder", nombre_jugador, respuesta})
  end

  @doc "Activa un poder guardado. `objetivo` se usa solo para robar_puntos."
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
    cond do
      sala.estado != "jugando" or sala.pregunta_actual == nil ->
        {:reply, {:error, "no_hay_pregunta_activa"}, sala}

      not puede_responder?(sala, nombre_jugador) ->
        {:reply, {:error, "no_puedes_responder"}, sala}

      Preguntas.respuesta_correcta?(sala.pregunta_actual, respuesta) ->
        sala = cancelar_temporizador(sala)
        sala = procesar_respuesta_correcta(sala, nombre_jugador)
        {:reply, {:ok, true}, sala}

      true ->
        sala = procesar_respuesta_incorrecta(sala, nombre_jugador)
        {:reply, {:ok, false}, sala}
    end
  end

  def handle_call({"usar_poder", nombre_jugador, poder, objetivo}, _from, sala) do
    cond do
      not jugador_puede_jugar?(sala, nombre_jugador) ->
        {:reply, {:error, "no_puedes_usar_poderes"}, sala}

      not tiene_poder?(sala, nombre_jugador, poder) ->
        {:reply, {:error, "no_tienes_ese_poder"}, sala}

      poder in ["congelar", "pista"] and sala.pregunta_actual == nil ->
        {:reply, {:error, "no_hay_pregunta_activa"}, sala}

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
      if sala.estado == "jugando" do
        avanzar_si_nadie_puede_responder(sala)
      else
        verificar_fin_de_partida(sala)
      end

    anunciar(sala, {"jugadores_actualizados", sala})
    {:noreply, sala}
  end

  @impl true
  def handle_info("tiempo_agotado", sala) do
    sala = finalizar_pregunta_sin_ganador(sala)
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
      avatar: "/images/gato#{posicion}.jpeg"
    }
  end

  # ============================================================
  # PREGUNTAS — quien puede responder
  # ============================================================

  defp jugadores_activos(jugadores) do
    Enum.filter(jugadores, fn j -> j.vidas > 0 and j.conectado end)
  end

  # Jugadores que todavia podrian responder la pregunta actual:
  # estan vivos/conectados Y no han fallado ya en esta pregunta.
  defp jugadores_disponibles_para_pregunta(sala) do
    sala.jugadores
    |> jugadores_activos()
    |> Enum.reject(fn j -> j.nombre in sala.intentos_fallidos end)
  end

  defp puede_responder?(sala, nombre_jugador) do
    case Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador)) do
      nil -> false
      jugador -> jugador.vidas > 0 and jugador.conectado and nombre_jugador not in sala.intentos_fallidos
    end
  end

  defp jugador_puede_jugar?(sala, nombre_jugador) do
    case Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador)) do
      nil -> false
      jugador -> jugador.vidas > 0 and jugador.conectado
    end
  end

  # ============================================================
  # TURNOS (cada turno = una pregunta abierta a todos)
  # ============================================================

  defp iniciar_turno(sala) do
    pregunta = Preguntas.aleatoria(sala.tematica)
    segundos = Preguntas.tiempo_segundos(pregunta)

    ref = Process.send_after(self(), "tiempo_agotado", segundos * 1000)

    sala = %{
      sala
      | pregunta_actual: pregunta,
        tiempo_restante: segundos,
        temporizador_ref: ref,
        intentos_fallidos: [],
        opciones_ocultas: [],
        letra_revelada: nil
    }

    anunciar(sala, {"nuevo_turno", sala})
    sala
  end

  defp cancelar_temporizador(sala) do
    if sala.temporizador_ref, do: Process.cancel_timer(sala.temporizador_ref)
    %{sala | temporizador_ref: nil}
  end

  # Si tras una desconexion ya no queda nadie que pueda intentar la
  # pregunta activa, se cierra esa pregunta sin ganador y se avanza.
  defp avanzar_si_nadie_puede_responder(sala) do
    sala = verificar_fin_de_partida(sala)

    if sala.estado == "jugando" and sala.pregunta_actual != nil and
         jugadores_disponibles_para_pregunta(sala) == [] do
      finalizar_pregunta_sin_ganador(sala)
    else
      sala
    end
  end

  # ============================================================
  # RESULTADO DE UNA RESPUESTA
  # ============================================================

  defp procesar_respuesta_correcta(sala, nombre_jugador) do
    sala =
      sala
      |> sumar_puntos(nombre_jugador)
      |> sumar_racha(nombre_jugador)

    anunciar(sala, {"respuesta_correcta", nombre_jugador})

    sala = incrementar_turnos(sala)
    sala = verificar_fin_de_partida(sala)

    if sala.estado == "jugando" do
      iniciar_turno(sala)
    else
      sala
    end
  end

  # Un jugador fallo: pierde vida (salvo que tenga escudo) y queda
  # fuera de esta pregunta, pero la pregunta sigue abierta para los
  # demas hasta que alguien acierte, se acabe el tiempo, o ya todos
  # hayan fallado tambien.
  defp procesar_respuesta_incorrecta(sala, nombre_jugador) do
    sala =
      sala
      |> aplicar_falla(nombre_jugador)
      |> registrar_intento_fallido(nombre_jugador)

    anunciar(sala, {"respuesta_incorrecta", nombre_jugador, sala})

    if jugadores_disponibles_para_pregunta(sala) == [] do
      finalizar_pregunta_sin_ganador(sala)
    else
      sala
    end
  end

  defp finalizar_pregunta_sin_ganador(sala) do
    sala = cancelar_temporizador(sala)
    sala = incrementar_turnos(sala)
    sala = verificar_fin_de_partida(sala)

    if sala.estado == "jugando" do
      iniciar_turno(sala)
    else
      sala
    end
  end

  defp registrar_intento_fallido(sala, nombre_jugador) do
    %{sala | intentos_fallidos: [nombre_jugador | sala.intentos_fallidos]}
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

  # congelar: efecto inmediato sobre el reloj COMPARTIDO de la pregunta
  # activa (le da mas tiempo a todos los que aun pueden responder, no
  # solo a quien lo usa). Se cancela el timer actual y se reprograma
  # con el tiempo restante + el bono.
  defp aplicar_poder(sala, nombre_jugador, "congelar", _objetivo) do
    sala = cancelar_temporizador(sala)
    nuevo_tiempo = sala.tiempo_restante + @bono_congelar

    ref = Process.send_after(self(), "tiempo_agotado", nuevo_tiempo * 1000)

    sala = %{sala | tiempo_restante: nuevo_tiempo, temporizador_ref: ref}
    anunciar(sala, {"tiempo_extendido", nombre_jugador, sala})
    sala
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

  # pista: ayuda visible para TODOS sobre la pregunta activa. Si es de
  # seleccion, oculta una opcion incorrecta; si es escrita, revela la
  # primera letra de la respuesta.
  defp aplicar_poder(sala, _nombre_jugador, "pista", _objetivo) do
    pregunta = sala.pregunta_actual

    case pregunta && pregunta["tipo"] do
      "seleccion" -> ocultar_opcion_incorrecta(sala, pregunta)
      "escrita" -> revelar_primera_letra(sala, pregunta)
      _ -> sala
    end
  end

  defp ocultar_opcion_incorrecta(sala, pregunta) do
    candidatas =
      pregunta["opciones"]
      |> Enum.reject(&(&1 == pregunta["respuesta"]))
      |> Enum.reject(&(&1 in sala.opciones_ocultas))

    case candidatas do
      [] -> sala
      _ -> %{sala | opciones_ocultas: [Enum.random(candidatas) | sala.opciones_ocultas]}
    end
  end

  defp revelar_primera_letra(sala, pregunta) do
    %{sala | letra_revelada: String.first(pregunta["respuesta"])}
  end

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
            pregunta_actual: nil
        }

        anunciar(sala, {"partida_finalizada", sala})
        sala

      [] ->
        sala = %{sala | estado: "finalizado", ganador: nil}
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
