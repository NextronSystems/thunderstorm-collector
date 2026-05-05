COLLECTOR_NAME="Python"

COLLECTOR_TESTS=(
    "basic_submission;-s localhost -p PORT --dirs TESTDIR;.[0].response | fromjson | .id;^[0-9]+$"
    "source_param;-s localhost -p PORT -S test-host --dirs TESTDIR;.[0].uri | capture(\"source=(?<src>[^&]*)\") | .src;^test-host$"
    "file_count;-s localhost -p PORT --dirs TESTDIR;length;^[1-9][0-9]*$"
)
