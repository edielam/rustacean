struct Cli {
    pattern: String,
    path: std::path::PathBuf, 
}
fn main() {
    let pattern = std::env::args().nth(1).expect("where is the pattern, bro?");
    let path = std::env::args().nth(2).expect("Can't find your file man");

    let args = Cli{
        pattern,
        path: std::path::PathBuf::from(path),
    };
    println!("Okay your pattern is {} and your path is {:?}",args.pattern, args.path)
}
