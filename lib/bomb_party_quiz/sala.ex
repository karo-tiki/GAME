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

  Cuando un jugador se queda sin vidas pasa a ser espectador, PERO si
  acumulo al menos @costo_revivir puntos y todavia no ha usado su
  unica oportunidad de revivir en esta partida, puede "comprar" 1
  vida de vuelta gastando esos puntos, en cualquier momento (no hace
  falta esperar a que cierre la pregunta actual). Esto le da un uso
  real a los puntos acumulados, mas alla de solo decidir el ganador.

  La partida termina apenas queda matematicamente decidida: si solo
  hay un jugador con vidas y ningun eliminado puede ya revivir
  (porque no le quedan puntos suficientes o ya gasto su oportunidad),
  se declara ganador de inmediato, sin esperar una ronda extra.

  Cada #{@intervalo_bomba_dirigida}ra pregunta es una "bomba dirigida":
  se elige a un jugador activo (usando una bolsa sin repetir, para que
  le toque a todos antes de que se repita alguien) y SOLO el puede
  responderla (no es libre como las demas). Si acierta, gana el doble
  de puntos. Si falla o se acaba el tiempo, pierde TODAS sus vidas y
  TODOS sus puntos (totales de la partida) de golpe, salvo que tenga
  un escudo activo (que absorbe el golpe igual que con una pregunta
  normal, sin perder vidas ni puntos). La pregunta se cierra de
  inmediato, nadie mas puede intentarla porque era solo para ese
  jugador. Esto evita que alguien gane solo por quedarse quieto sin
  arriesgar nada.

  La pista (poder) es privada: solo la ve quien la activo, no todos
  los jugadores. Quien la usa queda registrado como "beneficiario" de
  esa pregunta y es el unico que ve la opcion marcada como incorrecta
  o la primera letra revelada; el resto sigue viendo la pregunta sin
  ninguna ayuda.

  Para que la partida no sea eterna, se corta a las
  #{@max_preguntas} preguntas totales si para entonces nadie gano por
  el criterio normal de vidas: en ese caso gana quien tenga mas
  puntos acumulados entre los jugadores que siguen conectados.

  El poder escudo, una vez activado, solo protege durante la pregunta
  en la que se uso: si el jugador no falla en esa pregunta, el escudo
  se pierde igual al pasar a la siguiente. El poder sin activar si se
  puede guardar en el inventario el tiempo que el jugador quiera.

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
  @costo_revivir 100
  @intervalo_bomba_dirigida 3
  @max_preguntas 15
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
            multiplicador_puntos: 1,
            preguntas_totales: 0,
            objetivo_bomba: nil,
            objetivos_bomba_pendientes: [],
            beneficiarios_pista: []

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

  @doc """
  Permite a un jugador eliminado (0 vidas) comprar 1 vida de vuelta
  gastando #{@costo_revivir} puntos. Solo puede hacerse 1 vez por
  partida, y puede usarse en cualquier momento, sin esperar a que
  cierre la pregunta activa.
  """
  def comprar_vida(codigo, nombre_jugador) do
    GenServer.call(nombre_proceso(codigo), {"comprar_vida", nombre_jugador})
  end

  def desconectar(codigo, nombre_jugador) do
    GenServer.cast(nombre_proceso(codigo), {"desconectar", nombre_jugador})
  end

  def estado(codigo) do
    GenServer.call(nombre_proceso(codigo), "estado")
  end

  def topic(codigo), do: "sala:#{codigo}"

  def costo_revivir, do: @costo_revivir

  def max_preguntas, do: @max_preguntas

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

  def handle_call({"comprar_vida", nombre_jugador}, _from, sala) do
    jugador = Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador))

    cond do
      sala.estado != "jugando" ->
        {:reply, {:error, "partida_no_esta_en_curso"}, sala}

      jugador == nil ->
        {:reply, {:error, "jugador_no_encontrado"}, sala}

      jugador.vidas > 0 ->
        {:reply, {:error, "no_estas_eliminado"}, sala}

      jugador.revivio_usado ->
        {:reply, {:error, "ya_usaste_tu_revivir"}, sala}

      jugador.puntos < @costo_revivir ->
        {:reply, {:error, "puntos_insuficientes"}, sala}

      true ->
        sala =
          actualizar_jugador(sala, nombre_jugador, fn j ->
            %{j | vidas: 1, puntos: j.puntos - @costo_revivir, revivio_usado: true}
          end)

        sala = reanudar_si_estaba_pausado(sala)

        anunciar(sala, {"jugador_revivio", nombre_jugador, sala})
        {:reply, {:ok, sala}, sala}
    end
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
    sala =
      if sala.objetivo_bomba != nil do
        procesar_fallo_bomba(sala, sala.objetivo_bomba)
      else
        finalizar_pregunta_sin_ganador(sala)
      end

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
      revivio_usado: false,
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

  # Si hay un objetivo de bomba dirigida, SOLO el puede responder.
  # Si no, cualquiera con vidas que no haya fallado ya esta pregunta.
  defp puede_responder?(sala, nombre_jugador) do
    case Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador)) do
      nil ->
        false

      jugador ->
        cond do
          sala.objetivo_bomba != nil ->
            nombre_jugador == sala.objetivo_bomba and jugador.vidas > 0 and jugador.conectado

          true ->
            jugador.vidas > 0 and jugador.conectado and nombre_jugador not in sala.intentos_fallidos
        end
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

  # Cada @intervalo_bomba_dirigida preguntas se elige a un jugador
  # activo y se le "dirige" la bomba: solo el puede responderla. Las
  # demas preguntas siguen siendo libres para todos.
  #
  # El objetivo NO se elige con azar puro en cada turno (eso podria
  # repetir a la misma persona varias veces seguidas mientras otros
  # nunca la reciben). En vez de eso se usa una "bolsa sin repetir":
  # se sortea solo entre quienes todavia no les ha tocado en el ciclo
  # actual; cuando ya le toco a todos los jugadores activos, la bolsa
  # se reinicia para el siguiente ciclo. Asi se garantiza que la bomba
  # pase por todos antes de volver a repetirse.
  #
  # Al iniciar un turno nuevo, cualquier escudo que seguia activo de
  # la pregunta anterior se apaga: el escudo solo protege durante LA
  # pregunta en la que se activo, no se acarrea a la siguiente. El
  # poder en si (sin activar) se mantiene guardado en el inventario
  # del jugador hasta que el decida usarlo.
  defp iniciar_turno(sala) do
    sala = resetear_escudos(sala)

    nuevo_conteo = sala.preguntas_totales + 1
    candidatos = Enum.filter(sala.jugadores, fn j -> j.conectado and j.vidas > 0 end)
    es_bomba_dirigida = rem(nuevo_conteo, @intervalo_bomba_dirigida) == 0 and candidatos != []

    {objetivo, nuevos_pendientes} =
      if es_bomba_dirigida do
        elegir_objetivo_bomba(sala.objetivos_bomba_pendientes, candidatos)
      else
        {nil, sala.objetivos_bomba_pendientes}
      end

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
        letra_revelada: nil,
        beneficiarios_pista: [],
        preguntas_totales: nuevo_conteo,
        objetivo_bomba: objetivo,
        objetivos_bomba_pendientes: nuevos_pendientes
    }

    anunciar(sala, {"nuevo_turno", sala})
    sala
  end

  # Filtra la bolsa pendiente para quitar a quien ya no este activo
  # (desconectado o sin vidas). Si queda vacia (le toco a todos en
  # este ciclo, o es la primera vez), se reinicia con todos los
  # candidatos activos actuales. Luego sortea uno de la bolsa y lo
  # quita, para que no vuelva a salir hasta el proximo ciclo.
  defp elegir_objetivo_bomba(pendientes, candidatos) do
    nombres_candidatos = Enum.map(candidatos, & &1.nombre)

    bolsa =
      pendientes
      |> Enum.filter(&(&1 in nombres_candidatos))
      |> case do
        [] -> nombres_candidatos
        restantes -> restantes
      end

    elegido = Enum.random(bolsa)
    {elegido, List.delete(bolsa, elegido)}
  end

  defp cancelar_temporizador(sala) do
    if sala.temporizador_ref, do: Process.cancel_timer(sala.temporizador_ref)
    %{sala | temporizador_ref: nil}
  end

  defp resetear_escudos(sala) do
    jugadores = Enum.map(sala.jugadores, fn j -> %{j | escudo_activo: false} end)
    %{sala | jugadores: jugadores}
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

  defp hay_jugador_activo?(sala) do
    Enum.any?(sala.jugadores, fn j -> j.conectado and j.vidas > 0 end)
  end

  # Un jugador eliminado "puede revivir" si esta conectado, tiene
  # puntos suficientes y todavia no gasto su unica oportunidad.
  defp puede_revivir?(jugador) do
    jugador.conectado and jugador.vidas == 0 and not jugador.revivio_usado and
      jugador.puntos >= @costo_revivir
  end

  # Tras cerrar una pregunta: si ya se llego al limite de preguntas
  # de la partida, se corta ahi (gana quien tenga mas puntos). Si no,
  # se abre la siguiente (si hay alguien con vidas para jugarla) o la
  # partida queda en pausa esperando a que algun eliminado decida
  # comprar su vida de vuelta.
  defp continuar_o_pausar(sala) do
    cond do
      sala.estado != "jugando" -> sala
      sala.preguntas_totales >= @max_preguntas -> finalizar_por_limite_de_preguntas(sala)
      hay_jugador_activo?(sala) -> iniciar_turno(sala)
      true -> cancelar_temporizador(%{sala | pregunta_actual: nil})
    end
  end

  # Cuando alguien compra su vida de vuelta y la partida estaba en
  # pausa (sin pregunta activa porque nadie tenia vidas), se reanuda
  # con un turno nuevo, salvo que ya se haya llegado al limite de
  # preguntas mientras estaba en pausa.
  defp reanudar_si_estaba_pausado(sala) do
    cond do
      sala.estado != "jugando" or sala.pregunta_actual != nil -> sala
      sala.preguntas_totales >= @max_preguntas -> finalizar_por_limite_de_preguntas(sala)
      hay_jugador_activo?(sala) -> iniciar_turno(sala)
      true -> sala
    end
  end

  # Si la partida llega al limite de preguntas sin que el criterio
  # normal de vidas haya decidido un ganador, se corta ahi: gana quien
  # tenga mas puntos acumulados entre los jugadores que siguen
  # conectados (esten o no con vidas en ese momento).
  defp finalizar_por_limite_de_preguntas(sala) do
    ganador =
      sala.jugadores
      |> Enum.filter(& &1.conectado)
      |> Enum.max_by(& &1.puntos, fn -> nil end)

    sala = %{
      sala
      | estado: "finalizado",
        ganador: ganador && ganador.nombre,
        pregunta_actual: nil
    }

    anunciar(sala, {"partida_finalizada", sala})
    sala
  end

  # ============================================================
  # RESULTADO DE UNA RESPUESTA
  # ============================================================

  defp procesar_respuesta_correcta(sala, nombre_jugador) do
    doble_puntos? = sala.objetivo_bomba == nombre_jugador

    sala =
      sala
      |> sumar_puntos(nombre_jugador, doble_puntos?)
      |> sumar_racha(nombre_jugador)

    anunciar(sala, {"respuesta_correcta", nombre_jugador})

    sala = incrementar_turnos(sala)
    sala = verificar_fin_de_partida(sala)
    continuar_o_pausar(sala)
  end

  # Un jugador fallo. Si era una bomba dirigida hacia el, el castigo
  # es total (ver procesar_fallo_bomba). Si era una pregunta libre,
  # solo pierde 1 vida y queda fuera de ESTA pregunta, que sigue
  # abierta para los demas hasta que alguien acierte, se acabe el
  # tiempo, o ya todos hayan fallado tambien.
  #
  # Apenas se pierde una vida se revisa si la partida ya quedo
  # decidida (en vez de esperar a que cierre la pregunta), pero
  # respetando a quien todavia podria comprar su vida de vuelta.
  defp procesar_respuesta_incorrecta(sala, nombre_jugador) do
    if sala.objetivo_bomba == nombre_jugador do
      procesar_fallo_bomba(sala, nombre_jugador)
    else
      sala =
        sala
        |> aplicar_falla(nombre_jugador)
        |> registrar_intento_fallido(nombre_jugador)

      anunciar(sala, {"respuesta_incorrecta", nombre_jugador, sala})

      sala = verificar_fin_de_partida(sala)

      cond do
        sala.estado != "jugando" ->
          sala

        jugadores_disponibles_para_pregunta(sala) == [] ->
          finalizar_pregunta_sin_ganador(sala)

        true ->
          sala
      end
    end
  end

  # Fallar (o no responder a tiempo) una bomba dirigida es catastrofico:
  # el jugador pierde TODAS sus vidas y TODOS sus puntos de golpe,
  # salvo que tenga un escudo activo (que absorbe el golpe igual que
  # con una falla normal). La pregunta se cierra de inmediato, nadie
  # mas puede intentarla porque era SOLO para el.
  defp procesar_fallo_bomba(sala, nombre_jugador) do
    sala =
      sala
      |> aplicar_fallo_bomba(nombre_jugador)
      |> registrar_intento_fallido(nombre_jugador)

    anunciar(sala, {"bomba_fallo", nombre_jugador, sala})

    finalizar_pregunta_sin_ganador(sala)
  end

  defp aplicar_fallo_bomba(sala, nombre_jugador) do
    jugador = Enum.find(sala.jugadores, &(&1.nombre == nombre_jugador))

    if jugador.escudo_activo do
      actualizar_jugador(sala, nombre_jugador, fn j -> %{j | racha: 0, escudo_activo: false} end)
    else
      actualizar_jugador(sala, nombre_jugador, fn j -> %{j | vidas: 0, puntos: 0, racha: 0} end)
    end
  end

  defp finalizar_pregunta_sin_ganador(sala) do
    sala = cancelar_temporizador(sala)
    sala = incrementar_turnos(sala)
    sala = verificar_fin_de_partida(sala)
    continuar_o_pausar(sala)
  end

  defp registrar_intento_fallido(sala, nombre_jugador) do
    %{sala | intentos_fallidos: [nombre_jugador | sala.intentos_fallidos]}
  end

  defp sumar_puntos(sala, nombre_jugador, doble_puntos? \\ false) do
    segundos_sobrantes = sala.tiempo_restante
    base = (@puntos_base + segundos_sobrantes) * sala.multiplicador_puntos
    puntos = if doble_puntos?, do: base * 2, else: base

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

  # escudo: se activa y protege SOLO durante la pregunta en la que se
  # usa. Si el jugador no falla en esa pregunta, el escudo se pierde
  # igual al pasar a la siguiente (no se acarrea); no hace falta
  # fallar para "gastarlo". El poder en si puede guardarse en el
  # inventario el tiempo que el jugador quiera antes de activarlo.
  defp aplicar_poder(sala, nombre_jugador, "escudo", _objetivo) do
    actualizar_jugador(sala, nombre_jugador, fn j -> %{j | escudo_activo: true} end)
  end

  # pista: ayuda PRIVADA, solo visible para quien la activa. Se
  # registra a este jugador como "beneficiario" de la pregunta actual;
  # el resto de jugadores sigue viendo la pregunta sin ninguna ayuda.
  # Si es de seleccion, oculta (solo para el) una opcion incorrecta;
  # si es escrita, le revela (solo a el) la primera letra.
  defp aplicar_poder(sala, nombre_jugador, "pista", _objetivo) do
    sala = %{sala | beneficiarios_pista: Enum.uniq([nombre_jugador | sala.beneficiarios_pista])}
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

  # La partida termina solo cuando ya esta matematicamente decidida:
  #
  # - Si nadie tiene vidas y ningun eliminado puede ya revivir
  #   (sin puntos suficientes o ya gasto su oportunidad): termina sin
  #   ganador.
  # - Si queda exactamente 1 jugador con vidas Y ningun otro
  #   eliminado podria todavia revivir y volver a competir: ese
  #   jugador gana de inmediato.
  # - En cualquier otro caso (varios con vidas, o un eliminado que
  #   aun podria revivir) la partida sigue.
  defp verificar_fin_de_partida(sala) do
    conectados = Enum.filter(sala.jugadores, & &1.conectado)
    con_vidas = Enum.filter(conectados, &(&1.vidas > 0))
    pueden_revivir = Enum.filter(conectados, &puede_revivir?/1)

    cond do
      con_vidas == [] and pueden_revivir == [] ->
        sala = %{sala | estado: "finalizado", ganador: nil}
        anunciar(sala, {"partida_finalizada", sala})
        sala

      length(con_vidas) == 1 and pueden_revivir == [] ->
        [unico_ganador] = con_vidas

        sala = %{
          sala
          | estado: "finalizado",
            ganador: unico_ganador.nombre,
            pregunta_actual: nil
        }

        anunciar(sala, {"partida_finalizada", sala})
        sala

      true ->
        sala
    end
  end

  defp anunciar(sala, mensaje) do
    PubSub.broadcast(@pubsub, topic(sala.codigo), mensaje)
  end
end
