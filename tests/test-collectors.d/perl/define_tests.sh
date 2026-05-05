COLLECTOR_NAME="Perl"

COLLECTOR_TESTS=(
    "basic_submission;--server localhost:PORT --dir TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
    "source_param;--server localhost:PORT --source test-client --dir TESTDIR;.[0].uri | capture(\"source=(?<src>[^&]*)\") | .src;^test-client$"
    "file_count;--server localhost:PORT --dir TESTDIR;length;^[1-9][0-9]*$"
    "port_param;--server localhost --port PORT --dir TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
)
