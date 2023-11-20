# Function to create symbolic links
create_symlinks() {
    echo "Creating symbolic links..."
    # Read symlinks from the file and create them
    while IFS= read -r symlink || [[ -n "$symlink" ]]; do
        # Execute the symlink command
        eval "$symlink"
    done < symlinks.txt
    echo "Symbolic links created."
}

# Function to install packages
install_packages() {
    echo "Installing packages..."

    # Read package names from the file and install them
    while IFS= read -r package || [[ -n "$package" ]]; do
        # Adjust the package manager command based on your distribution (e.g., pacman, apt, dnf)
        sudo pacman -Syu "$package"
    done < pkglist.txt

    echo "Packages installed."
}

# Execute functions
install_packages
create_symlinks