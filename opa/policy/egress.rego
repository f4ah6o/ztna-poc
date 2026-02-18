package egress

default allow := true

allow := false if {
  denied := data.egress.deny_domains[_]
  domain_matches(input.domain, denied)
}

domain_matches(domain, denied) if {
  domain == denied
}

domain_matches(domain, denied) if {
  endswith(domain, sprintf(".%s", [denied]))
}
