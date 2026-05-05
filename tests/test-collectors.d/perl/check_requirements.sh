collector_check_requirements() {
    if ! command -v $PERL_CMD >/dev/null 2>&1; then
        echo "ERROR: Perl interpreter not found ($PERL_CMD)"
        echo "Install with: choco install strawberryperl (Windows) or apt-get install perl (Linux)"
        return 1
    fi
    if ! $PERL_CMD -MLWP::UserAgent -e 1 2>/dev/null; then
        echo "ERROR: Perl LWP::UserAgent module not found"
        echo "Install with: apt-get install libwww-perl (Linux) or cpan LWP::UserAgent"
        return 1
    fi
}
