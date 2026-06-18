defmodule BombPartyQuiz.Preguntas do
  @moduledoc """
  Carga el banco de preguntas desde priv/preguntas.json y ofrece
  funciones para obtener preguntas aleatorias por temática.
  """

  def todas do
    ruta_json()
    |> File.read!()
    |> JSON.decode!()
  end

  defp ruta_json do
    :code.priv_dir(:bomb_party_quiz)
    |> Path.join("preguntas.json")
  end

  def por_tematica(tematica) do
    todas()
    |> Enum.filter(fn pregunta -> pregunta["tematica"] == tematica end)
  end

  def aleatoria(tematica) do
    tematica
    |> por_tematica()
    |> Enum.random()
  end

  def tiempo_segundos(%{"tipo" => "seleccion"}), do: 15
  def tiempo_segundos(%{"tipo" => "escrita"}), do: 30

  def respuesta_correcta?(pregunta, respuesta_jugador) do
    normalizar(pregunta["respuesta"]) == normalizar(respuesta_jugador)
  end

  defp normalizar(texto) when is_binary(texto) do
    texto |> String.trim() |> String.downcase()
  end

  defp normalizar(_), do: ""
end
