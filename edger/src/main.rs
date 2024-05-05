Struct Cli {
    pattern: String;
    path: std::path::PathBuf, 
}
fn main() {
    let pattern = std::env::args().nth(1).expect("where is the pattern, bro?");
    let path = std::env::args().nth(2).expect("Can't find your file man");

    let args = Cli{
        
    }
    println!("Okay your pattern is {} and your path is {}",pattern, path)
}
