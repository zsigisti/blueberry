//! pacman's vercmp, ported straight from the C bpm's vercmp.c.
//! `[epoch:]ver[-rel]`, compared in digit/letter runs so 1.10 > 1.9.

use std::cmp::Ordering;

fn is_alnum(c: u8) -> bool {
    c.is_ascii_alphanumeric()
}

/// One segment (epoch, ver or rel).
fn rpmvercmp(a: &str, b: &str) -> Ordering {
    if a == b {
        return Ordering::Equal;
    }
    let one = a.as_bytes();
    let two = b.as_bytes();
    let (mut i, mut j) = (0usize, 0usize);

    loop {
        while i < one.len() && !is_alnum(one[i]) {
            i += 1;
        }
        while j < two.len() && !is_alnum(two[j]) {
            j += 1;
        }
        if i >= one.len() || j >= two.len() {
            break;
        }

        let (s1, s2) = (i, j);
        let isnum = one[i].is_ascii_digit();
        if isnum {
            while i < one.len() && one[i].is_ascii_digit() {
                i += 1;
            }
            while j < two.len() && two[j].is_ascii_digit() {
                j += 1;
            }
        } else {
            while i < one.len() && one[i].is_ascii_alphabetic() {
                i += 1;
            }
            while j < two.len() && two[j].is_ascii_alphabetic() {
                j += 1;
            }
        }

        // one side is a number where the other has letters: number wins
        if s1 == i {
            return if isnum { Ordering::Greater } else { Ordering::Less };
        }
        if s2 == j {
            return if isnum { Ordering::Greater } else { Ordering::Less };
        }

        let mut r1 = &one[s1..i];
        let mut r2 = &two[s2..j];
        if isnum {
            while r1.len() > 1 && r1[0] == b'0' {
                r1 = &r1[1..];
            }
            while r2.len() > 1 && r2[0] == b'0' {
                r2 = &r2[1..];
            }
            if r1.len() != r2.len() {
                return r1.len().cmp(&r2.len());
            }
        }
        match r1.cmp(r2) {
            Ordering::Equal => {}
            ord => return ord,
        }
    }

    // longer one wins, unless what's left is letters: 1.0 > 1.0alpha, like pacman
    let rest1 = i < one.len();
    let rest2 = j < two.len();
    match (rest1, rest2) {
        (true, false) => {
            if one[i].is_ascii_alphabetic() {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        }
        (false, true) => {
            if two[j].is_ascii_alphabetic() {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        }
        _ => Ordering::Equal,
    }
}

fn split(v: &str) -> (&str, &str, &str) {
    let (epoch, rest) = match v.split_once(':') {
        Some((e, r)) => (e, r),
        None => ("0", v),
    };
    let (ver, rel) = match rest.rsplit_once('-') {
        Some((ve, re)) => (ve, re),
        None => (rest, "0"),
    };
    (epoch, ver, rel)
}

pub fn vercmp(a: &str, b: &str) -> Ordering {
    let (ea, va, ra) = split(a);
    let (eb, vb, rb) = split(b);
    match rpmvercmp(ea, eb) {
        Ordering::Equal => {}
        o => return o,
    }
    match rpmvercmp(va, vb) {
        Ordering::Equal => {}
        o => return o,
    }
    rpmvercmp(ra, rb)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering::*;
    #[test]
    fn ordering() {
        assert_eq!(vercmp("1.10", "1.9"), Greater);
        assert_eq!(vercmp("16.1.0-2", "16.1.0-1"), Greater);
        assert_eq!(vercmp("1.0", "1.0"), Equal);
        assert_eq!(vercmp("2.0", "1.9"), Greater);
        assert_eq!(vercmp("1:1.0", "2.0"), Greater);
        assert_eq!(vercmp("1.0-1", "1.0-2"), Less);
    }
}
