import random

# The gallows drawings, one for each number of wrong guesses (0 to 6)
STAGES = [
    """
  +---+
  |   |
      |
      |
      |
      |
=========""",
    """
  +---+
  |   |
  O   |
      |
      |
      |
=========""",
    """
  +---+
  |   |
  O   |
  |   |
      |
      |
=========""",
    """
  +---+
  |   |
  O   |
 /|   |
      |
      |
=========""",
    """
  +---+
  |   |
  O   |
 /|\\  |
      |
      |
=========""",
    """
  +---+
  |   |
  O   |
 /|\\  |
 /    |
      |
=========""",
    """
  +---+
  |   |
  O   |
 /|\\  |
 / \\  |
      |
=========""",
]

MAX_WRONG = len(STAGES) - 1

# Word lists sorted by difficulty
WORDS = {
    "easy": ["cat", "dog", "sun", "tree", "book", "fish", "cake", "ball"],
    "medium": ["python", "school", "laptop", "planet", "garden", "rocket"],
    "hard": ["algorithm", "variable", "recursion", "keyboard", "function"],
}


def alert(text):
    print("-" * len(text))
    print(text.upper())
    print("-" * len(text))


def choose_difficulty():
    while True:
        choice = input("Choose a difficulty (easy / medium / hard): ").strip().lower()
        if choice in WORDS:
            return choice
        print("That isn't a difficulty, try again.")


def pick_word(difficulty):
    return random.choice(WORDS[difficulty])


def hidden_word(word, guessed_letters):
    # Shows the letters that have been guessed and underscores for the rest
    shown = []
    for letter in word:
        if letter in guessed_letters:
            shown.append(letter)
        else:
            shown.append("_")
    return " ".join(shown)


def has_won(word, guessed_letters):
    for letter in word:
        if letter not in guessed_letters:
            return False
    return True


def get_guess(guessed_letters):
    while True:
        guess = input("Guess a letter: ").strip().lower()
        if len(guess) != 1 or not guess.isalpha():
            print("Please enter a single letter.")
        elif guess in guessed_letters:
            print("You already guessed that letter.")
        else:
            return guess


def play_round():
    word = pick_word(choose_difficulty())
    guessed_letters = set()
    wrong_guesses = 0

    while wrong_guesses < MAX_WRONG:
        print(STAGES[wrong_guesses])
        print("Word:", hidden_word(word, guessed_letters))
        print("Guessed so far:", " ".join(sorted(guessed_letters)))

        guess = get_guess(guessed_letters)
        guessed_letters.add(guess)

        if guess in word:
            print("Nice!", guess, "is in the word.")
            if has_won(word, guessed_letters):
                alert("You win! The word was " + word)
                return True
        else:
            wrong_guesses = wrong_guesses + 1
            print("Sorry,", guess, "is not in the word.")

    print(STAGES[wrong_guesses])
    alert("Game over! The word was " + word)
    return False


def menu():
    alert("Welcome to hangman")
    wins = 0
    games = 0
    while True:
        if play_round():
            wins = wins + 1
        games = games + 1
        print("Score:", wins, "out of", games)
        again = input("Play again? (y/n): ").strip().lower()
        if again != "y":
            print("Thanks for playing!")
            break


if __name__ == "__main__":
    menu()

"""
Next steps:

Let the player guess the whole word at once
Load words from a text file instead of a list
Add a hint option that costs a life

Note, Currently does work:

Picking a random word by difficulty
Showing the gallows after every guess
Rejecting repeated guesses and non-letters
Keeping score across rounds
"""