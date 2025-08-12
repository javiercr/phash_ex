#!/usr/bin/env elixir

# Test compilation manually
IO.puts("Testing pHash compilation...")

# Test if the pHash directory exists
if File.exists?("c_lib/pHash/CMakeLists.txt") do
  IO.puts("✅ CMakeLists.txt exists")
else
  IO.puts("❌ CMakeLists.txt missing")
end

# Test running the compilation task
try do
  Mix.Tasks.Compile.PHash.run([])
  IO.puts("✅ Compilation task completed")
rescue
  e -> IO.puts("❌ Compilation failed: #{inspect(e)}")
end

# Check if files were created
if File.exists?("priv/phash_nifs.dylib") do
  IO.puts("✅ NIF library created")
else
  IO.puts("❌ NIF library not found")
end
