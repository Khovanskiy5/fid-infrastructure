package = 'voting'
version = 'scm-1'
source  = {
    url = '/dev/null',
}
-- Put any modules your app depends on here
dependencies = {
    'checks == 3.3.0-1',
    'cartridge == 2.16.3-1',
    'vshard >= 0.1.26-1',
    'metrics == 0.13.0-1',
    'cartridge-cli-extensions == 1.1.2-1',
    'cartridge-metrics-role == 0.1.1-1',
    'cartridge-extensions == 1.1.0-1',
    'luasodium == 2.4.0-1'
}
build = {
    type = 'none';
}
