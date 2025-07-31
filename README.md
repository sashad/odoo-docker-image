# This is a odoo docker image with OCA apps and modules.

## build image
```
docker buildx build --tag odoo.oca.ostwind.17:latest .
```

## run
```
docker run --add-host db=172.17.0.1 -v odoo-data:/var/lib/odoo -v ./src:/mnt/extra-addons --rm -it --name=feature123.test.1vp.ru odoo.oca.ostwind.17:latest
```
Where:
- odoo-data: local storage volume.
- ./src: user's addons directories under develop or any extra addons.

# direnv

## Add to .bashrc
```bash
# direnv
show_virtual_env() {
  if [[ -n "$VIRTUAL_ENV" && -n "$DIRENV_DIR" ]]; then
    echo "($(basename $VIRTUAL_ENV)) "
  fi
}
export -f show_virtual_env
PS1='$(show_virtual_env)'$PS1

eval "$(direnv hook bash)"
# direnv
```
