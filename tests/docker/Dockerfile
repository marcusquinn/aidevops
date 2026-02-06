# Alpine-based test environment for setup scripts
FROM alpine:3.19

RUN apk add --no-cache bash curl git jq sudo coreutils grep sed && \
    adduser -D -s /bin/bash testuser && \
    echo "testuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER testuser
WORKDIR /home/testuser
RUN mkdir -p ~/git ~/.config/aidevops ~/.agents/{tmp,work,memory}

ENV HOME=/home/testuser
CMD ["/bin/bash"]
