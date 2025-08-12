defmodule Mix.Tasks.Compile.PHash do
  @doc """
  If the files don't exist or are older then sources, recompile them.

  FIXME: This seems to run every time when tests are run, strangely.
  """
  def run(_args) do
    priv = Path.join(__DIR__, "priv/")

    # Initialize pHash library if not already present
    unless File.exists?("c_lib/pHash/CMakeLists.txt") do
      IO.puts("pHash library not found, downloading...")

      # Try git submodule first (for development)
      case System.cmd("git", ["submodule", "update", "--init", "--recursive"]) do
        {_, 0} ->
          IO.puts("Successfully initialized git submodules")
        _ ->
          # Fallback: download pHash library directly
          IO.puts("Git submodules not available, downloading pHash library directly...")
          # Use the latest stable commit (Sep 2022) which includes important CMake fixes
          phash_commit = "dea9ffca729841db087f46a7389dd8610a629dc6"
          phash_url = "https://github.com/aetilius/pHash/archive/#{phash_commit}.zip"

          with {_, 0} <- System.cmd("curl", ["-L", "-o", "/tmp/phash.zip", phash_url]),
               {_, 0} <- System.cmd("unzip", ["-o", "/tmp/phash.zip", "-d", "/tmp/"]),
               :ok <- File.rm_rf("c_lib/pHash"),
               {_, 0} <- System.cmd("mv", ["/tmp/pHash-#{phash_commit}", "c_lib/pHash"]),
               :ok <- File.rm("/tmp/phash.zip") do
            IO.puts("Successfully downloaded pHash library")
          else
            _ ->
              raise "Failed to download pHash library. Please ensure curl and unzip are available, or clone the repository with submodules."
          end
      end
    end

    files = [
      {"c_lib/pHash/src/pHash.cpp", "#{priv}/libpHash.1.0.0#{shared_lib_ext()}"},
      {"c_lib/phash_nifs.cpp", "#{priv}/phash_nifs#{shared_lib_ext()}"}
    ]

    should_rebuild =
      Enum.any?(
        files,
        fn {from, result} ->
          not File.exists?(result) or
            (
              File.stat!(from).mtime > File.stat!(result).mtime
            )
        end
      )

    if should_rebuild do
      # Get homebrew prefix once for macOS
      homebrew_prefix = if :os.type() == {:unix, :darwin} do
        String.trim(elem(System.cmd("brew", ["--prefix"]), 0))
      else
        nil
      end

      cmake_env =
        if homebrew_prefix do
          [
            {"LDFLAGS", "-L#{homebrew_prefix}/lib"},
            {"CPPFLAGS", "-I#{homebrew_prefix}/include"}
          ]
        else
          []
        end

      cmake_args =
        if homebrew_prefix do
          [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=FALSE",
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
            "-DCMAKE_PREFIX_PATH=#{homebrew_prefix}",
            "-DCMAKE_LIBRARY_PATH=#{homebrew_prefix}/lib",
            "-DCMAKE_INCLUDE_PATH=#{homebrew_prefix}/include",
            "-DCMAKE_EXE_LINKER_FLAGS=-L#{homebrew_prefix}/lib",
            "-DCMAKE_SHARED_LINKER_FLAGS=-L#{homebrew_prefix}/lib",
            "-Wno-dev",  # Suppress developer warnings
            "."
          ]
        else
          ["-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=FALSE", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-Wno-dev", "."]
        end

      erlang_root =
        to_string(:code.root_dir() ++ ~c"/erts-" ++ :erlang.system_info(:version))

      gpp_args =
        if :os.type() == {:unix, :darwin} do
          [
            "phash_nifs.cpp",
            "-w",  # Suppress all warnings
            "-I#{erlang_root}/include",
            "-I#{brew_prefix("libpng")}/include",
            "-I#{brew_prefix("jpeg")}/include",
            "-I#{brew_prefix("libtiff")}/include",
            "-IpHash/src",
            "-IpHash/third-party/CImg",
            "-LpHash/Release",
            "-L#{brew_prefix("libpng")}/lib",
            "-L#{brew_prefix("jpeg")}/lib",
            "-L#{brew_prefix("libtiff")}/lib",
            "-L#{erl_interface_lib_path!()}/lib",
            "-lei",
            "-lpHash",
            "-Wl,-rpath,@loader_path",
            "-undefined",
            "dynamic_lookup",
            "-fpic",
            "-shared",
            "-o",
            "#{priv}/phash_nifs#{shared_lib_ext()}"
          ]
        else
          [
            "phash_nifs.cpp",
            "-w",  # Suppress all warnings
            "-I#{erlang_root}/include",
            "-IpHash/src",
            "-IpHash/third-party/CImg",
            "-LpHash/Release",
            "-L#{erl_interface_lib_path!()}/lib",
            "-lei",
            "-lerl_nif",
            "-lpHash",
            "-fpic",
            "-shared",
            "-Wl,-rpath,$ORIGIN",
            "-o#{priv}/phash_nifs#{shared_lib_ext()}"
          ]
        end

      IO.puts("Compiling pHash library...")

      with {_, 0} <-
             System.cmd(
               "cmake",
               cmake_args,
               cd: "c_lib/pHash",
               env: cmake_env,
               stderr_to_stdout: true
             ),
           {_, 0} <-
             System.cmd(
               "cmake",
               ["--build", ".", "--target", "pHash"],
               cd: "c_lib/pHash",
               env: cmake_env,
               stderr_to_stdout: true
             ),
           File.cp!(
             "c_lib/pHash/Release/libpHash.1.0.0#{shared_lib_ext()}",
             "#{priv}/libpHash.1.0.0#{shared_lib_ext()}"
           ),
           _ <- IO.puts("Compiling NIF bindings..."),
           {_, 0} <-
             System.cmd(
               "g++",
               gpp_args,
               cd: "c_lib",
               stderr_to_stdout: true
             ),
            File.ln_s(
                "phash_nifs#{shared_lib_ext()}",
                "#{priv}/phash_nifs.so"
            ) do
        :ok
      else
        _ -> {:error, ["compilation failed"]}
      end
    else
      :ok
    end
  end

  defp brew_prefix(lib) do
    {output, 0} = System.cmd("brew", ["--prefix", lib])
    String.trim(output)
  end

  defp shared_lib_ext do
    if :os.type() == {:unix, :darwin}, do: ".dylib", else: ".so"
  end

  defp erl_interface_lib_path! do
    erlang_lib_dir = Path.join(to_string(:code.root_dir()), "lib")

    case File.ls(erlang_lib_dir) do
      {:ok, files} ->
        case Enum.find(files, &String.starts_with?(&1, "erl_interface")) do
          nil ->
            raise "erl_interface lib not found"

          erl_interface_dir ->
            Path.join(erlang_lib_dir, erl_interface_dir)
        end

      {:error, _} ->
        raise "Could not list erlang lib directory"
    end
  end
end

defmodule PHash.MixProject do
  use Mix.Project

  def project do
    [
      app: :phash,
      version: "0.1.3",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:p_hash] ++ Mix.compilers(),
      description: """
      Bindings to the C++ pHash library (phash.org).
      """,
      source_url: "https://github.com/vaartis/phash_ex/",
      package:
        [
          maintainers: ["vaartis"],
          links: %{
            "GitHub" => "https://github.com/vaartis/phash_ex/"
          },
          licenses: ["GPL-3.0-or-later"],
          files:
            [
              "lib",
              "test",
              "priv",
              "mix.exs",
              "README.md",
              "LICENSE",
              "c_lib/*.cpp",
              "c_lib/pHash/COPYING",
              "c_lib/pHash/CMakeLists.txt",
              "c_lib/pHash/third-party/",
              "c_lib/pHash/src/",
              # These need to be here because it doesn't build without them
              "c_lib/pHash/examples/",
              "c_lib/pHash/bindings/CMakeLists.txt"
            ] ++ Enum.reject(
              Path.wildcard("c_lib/pHash/bindings/java/**/*"),
              fn path ->
                Path.extname(path) in [".so", ".java"] or File.dir?(path)
              end
            )
        ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [extra_applications: [:logger]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:temp, "~> 0.4"},
      {:ex_doc, "~> 0.22", only: :dev},
      {:unsafe, "~> 1.0"}
    ]
  end
end
