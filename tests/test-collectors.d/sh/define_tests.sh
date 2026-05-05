COLLECTOR_NAME="Shell"

COLLECTOR_TESTS=(
    "basic_submission;;.[0].response | fromjson | .id;^[0-9]+$"
    "file_count;;length;^[1-9][0-9]*$"
)
