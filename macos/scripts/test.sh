#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'Mac adapter tests require macOS.' >&2; exit 69; }
cd "$project_dir"
output="$project_dir/tests/run-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$output/module-cache" \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/ControllerPolicy.swift tests/ModelTests.swift -o "$output/model-tests"
MAGIC_BAY_TEST_OUTPUT="$output" "$output/model-tests" > "$output/model-tests.log" 2>&1 || { cat "$output/model-tests.log"; exit 1; }
cat "$output/model-tests.log"
prefix="$project_dir/dependencies/libusb-1.0.30-macos14"
xcrun clang -Wall -Wextra -Wpedantic -fsanitize=address,undefined -g -I"$prefix/include/libusb-1.0" \
    tests/backend_tests.c "$prefix/lib/libusb-1.0.a" -framework IOKit -framework CoreFoundation -framework Security -o "$output/backend-tests"
"$output/backend-tests" > "$output/backend-tests.log" 2>&1 || { cat "$output/backend-tests.log"; exit 1; }
cat "$output/backend-tests.log"
xcrun clang -Wall -Wextra -Wpedantic -fsanitize=address,undefined -g -I"$prefix/include/libusb-1.0" \
    tests/backend_hotplug_regression.c "$prefix/lib/libusb-1.0.a" -framework IOKit -framework CoreFoundation -framework Security -o "$output/hotplug-tests"
"$output/hotplug-tests" > "$output/hotplug-tests.log" 2>&1 || { cat "$output/hotplug-tests.log"; exit 1; }
cat "$output/hotplug-tests.log"
xcrun clang -Wall -Wextra -Wpedantic -fsanitize=address,undefined -g -I"$prefix/include/libusb-1.0" \
    tests/backend_stop_reason_tests.c "$prefix/lib/libusb-1.0.a" -framework IOKit -framework CoreFoundation -framework Security -o "$output/stop-reason-tests"
"$output/stop-reason-tests" > "$output/stop-reason-tests.log" 2>&1 || { cat "$output/stop-reason-tests.log"; exit 1; }
cat "$output/stop-reason-tests.log"
xcrun clang -Wall -Wextra -Wpedantic -fsanitize=address,undefined -g -I"$prefix/include/libusb-1.0" \
    tests/backend_readonly_tests.c -o "$output/readonly-tests"
"$output/readonly-tests" > "$output/readonly-tests.log" 2>&1 || { cat "$output/readonly-tests.log"; exit 1; }
cat "$output/readonly-tests.log"
xcrun clang -Wall -Wextra -Wpedantic -fsanitize=address,undefined -g -I"$prefix/include/libusb-1.0" \
    tests/backend_diagnostics_tests.c "$prefix/lib/libusb-1.0.a" -framework IOKit -framework CoreFoundation -framework Security -o "$output/diagnostic-tests"
"$output/diagnostic-tests" > "$output/diagnostic-tests.log" 2>&1 || { cat "$output/diagnostic-tests.log"; exit 1; }
cat "$output/diagnostic-tests.log"
xcrun swiftc -swift-version 5 -module-cache-path "$output/module-cache" \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/ControllerPolicy.swift Sources/AppController.swift tests/AppControllerTests.swift \
    -framework Cocoa -o "$output/app-controller-tests"
"$output/app-controller-tests" > "$output/app-controller-tests.log" 2>&1 || { cat "$output/app-controller-tests.log"; exit 1; }
cat "$output/app-controller-tests.log"
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/test_monitor_faults.py -v > "$output/observer-tests.log" 2>&1 || { cat "$output/observer-tests.log"; exit 1; }
cat "$output/observer-tests.log"
/bin/sh -n resources/install-helper
/bin/sh -n scripts/build.sh
echo "test_output=$output"
