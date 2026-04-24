FROM ocaml/opam:debian-ocaml-5.4
COPY --from=hadolint/hadolint:latest-alpine /bin/hadolint /bin/hadolint

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN ln -fs /usr/bin/opam-2.5 /usr/bin/opam

RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  curl \
  git \
  wget \
  zsh \
  && rm -rf /var/lib/apt/lists/*

# WTF: https://github.com/mirage/ocaml-cohttp/issues/675
RUN bash -c 'echo "http		80/tcp	www		# WorldWideWeb HTTP" >> /etc/services' \
  && bash -c 'echo "https		443/tcp	www		# WorldWideWeb HTTPS" >> /etc/services'

USER opam

# Install and configure zsh with oh-my-zsh
# hadolint ignore=SC2016
RUN wget --progress=dot:giga https://github.com/robbyrussell/oh-my-zsh/raw/master/tools/install.sh -q -O - | zsh \
  && cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc \
  && sed -i "/^plugins=/c\plugins=(git dotenv)" ~/.zshrc \
  && echo 'alias make="make -f /workspace/.devcontainer/Makefile"' >> ~/.zshrc
