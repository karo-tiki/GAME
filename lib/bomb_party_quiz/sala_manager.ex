defmodule BombPartyQuiz.SalaManager do
  @moduledoc """
  Crea y gestiona los procesos `Sala` dinámicamente usando un
  DynamicSupervisor, y genera códigos únicos de sala.
  """
  alias BombPartyQuiz.Sala

  def crear_sala do
    codigo = generar_codigo()

    if Sala.existe?(codigo) do
      crear_sala()
    else
      {:ok, _pid} = DynamicSupervisor.start_child(BombPartyQuiz.SalaSupervisor, {Sala, codigo})
      {:ok, codigo}
    end
  end

  defp generar_codigo do
    caracteres = ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    1..4
    |> Enum.map(fn _ -> Enum.random(caracteres) end)
    |> List.to_string()
  end
end
